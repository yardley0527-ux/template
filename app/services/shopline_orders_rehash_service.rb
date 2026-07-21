# frozen_string_literal: true

require Rails.root.join("lib/shopline_orders_maintenance_lock") if defined?(Rails)

# Recomputes source_row_hash for existing shopline_orders rows using the
# canonical formula in ShoplineOrder.content_hash (order_number + product_name
# + quantity + checkout_amount + occurrence — total_amount no longer
# participates, see that method's comment for why).
#
# REQUIRED before the new PaidOrdersWorkbookImporter is used against a
# database that still has hashes computed with the old formula: without this,
# the very next import would fail to match any existing row by hash (old
# formula ≠ new formula) and duplicate the entire table. This only UPDATEs
# the hash column — no rows are created or deleted — and is idempotent
# (running it twice produces the same hashes, so re-running after a partial
# apply is always safe).
#
# Historical rows have no stored "encounter order within the source file", so
# occurrence is derived from id ASC (insertion order) partitioned by
# (order_number, normalized product_name, quantity, normalized
# checkout_amount) — the best available stand-in. This also means rows that
# are pattern-A duplicates (same content, one has total_amount, one is NULL)
# get DISTINCT occurrence numbers (1, 2, ...) and therefore distinct hashes —
# they do not collide against the unique index, and this task can safely run
# whether or not the pattern-A dedupe cleanup has already happened.
#
# Occurrence MUST be computed over the whole table in one pass, not batch by
# batch — find_in_batches groups by primary key only, so if a duplicate-
# signature group straddled a batch boundary, restarting the counter at 1 in
# the second batch would collide two unrelated rows onto the same hash. All
# ~42k rows are plucked into memory for the compute pass (a few MB, in line
# with existing full-period plucks elsewhere in this codebase); only the
# WRITE phase is batched.
#
# dry_run computes the exact same plan apply would use — including a full
# collision check across the ENTIRE resulting hash space (not just changed
# rows) — proof, not assumption, that applying it cannot violate the unique
# index. apply recomputes this plan fresh (never trusts a prior dry-run) and
# refuses to write anything if the fresh check finds any collision.
class ShoplineOrdersRehashService
  WRITE_BATCH_SIZE = 2_000
  # Rough, honest estimate from observed local timing (~42k rows, batches of
  # WRITE_BATCH_SIZE each inside their own transaction) — not an SLA.
  ESTIMATED_SECONDS_PER_WRITE_BATCH = 0.05

  def self.call(apply: false)
    new(apply: apply).call
  end

  def initialize(apply: false)
    @apply = apply
  end

  def call
    return run_dry_run unless @apply

    acquired, result = ShoplineOrdersMaintenanceLock.try_with_lock { run_apply }
    return result if acquired

    { total_rows: ShoplineOrder.count, applied: false, aborted: true,
      abort_reason: "lock_busy — the importer or another rehash/dedupe run holds " \
                    "#{ShoplineOrdersMaintenanceLock::NAME}" }
  end

  private

  def run_dry_run
    started = monotonic_now
    plan = build_plan
    elapsed = monotonic_now - started

    report(plan).merge(applied: false, compute_seconds: elapsed.round(3),
                       estimated_apply_seconds: estimate_apply_seconds(plan))
  end

  def run_apply
    plan = build_plan # always fresh — never trust a prior dry-run's plan

    unless plan[:collisions].empty?
      return report(plan).merge(
        applied: false, aborted: true,
        abort_reason: "collision_detected — #{plan[:collisions].size} target hash(es) would be " \
                      "shared by multiple rows; refusing to write. This should be cryptographically " \
                      "near-impossible — investigate before retrying."
      )
    end

    write!(plan[:changes])
    report(plan).merge(applied: true, verification: verify(plan))
  end

  # ── Plan (shared by dry-run and apply — the single source of truth) ────

  def build_plan
    rows = ShoplineOrder
      .order(:order_number, :product_name, :quantity, :checkout_amount, :id)
      .pluck(:id, :order_number, :product_name, :quantity, :checkout_amount, :source_row_hash, :import_run_id)

    occurrence_counts       = Hash.new(0)
    signature_group_sizes   = Hash.new(0)
    target_hash_owners      = Hash.new { |h, k| h[k] = [] }
    changes                 = []
    unchanged_rows          = 0
    missing_identity_ids    = []
    affected_import_run_ids = Set.new

    rows.each do |id, order_number, product_name, quantity, checkout_amount, old_hash, import_run_id|
      missing_identity_ids << id if order_number.blank? || product_name.blank? || quantity.nil?

      signature = [
        order_number, ShoplineOrder.normalize_product_name(product_name),
        quantity.to_i, ShoplineOrder.format_decimal(checkout_amount)
      ]
      signature_group_sizes[signature] += 1
      occurrence_counts[signature] += 1

      new_hash = ShoplineOrder.content_hash(
        order_number: order_number, product_name: product_name,
        quantity: quantity, checkout_amount: checkout_amount,
        occurrence: occurrence_counts[signature]
      )
      target_hash_owners[new_hash] << id

      if new_hash == old_hash
        unchanged_rows += 1
      else
        changes << { id: id, old_hash: old_hash, new_hash: new_hash }
        affected_import_run_ids << import_run_id if import_run_id
      end
    end

    {
      total_rows: rows.size,
      unchanged_rows: unchanged_rows,
      changes: changes,
      collisions: target_hash_owners.select { |_hash, ids| ids.size > 1 },
      rows_missing_required_identity: missing_identity_ids,
      ambiguous_occurrence_groups: signature_group_sizes.count { |_sig, n| n > 1 },
      affected_import_run_ids: affected_import_run_ids
    }
  end

  def report(plan)
    {
      total_rows: plan[:total_rows],
      unchanged_rows: plan[:unchanged_rows],
      changed_rows: plan[:changes].size,
      rows_to_rehash: plan[:changes].size, # kept for backward compatibility with existing callers
      collision_groups: plan[:collisions].size,
      collision_rows: plan[:collisions].values.sum(&:size),
      duplicate_target_hashes: plan[:collisions].map { |hash, ids| { hash: hash, row_count: ids.size } },
      rows_missing_required_identity: plan[:rows_missing_required_identity].size,
      ambiguous_occurrence_groups: plan[:ambiguous_occurrence_groups],
      affected_import_runs: plan[:affected_import_run_ids].size,
      safe_to_apply: plan[:collisions].empty?
    }
  end

  def estimate_apply_seconds(plan)
    batches = (plan[:changes].size.to_f / WRITE_BATCH_SIZE).ceil
    (batches * ESTIMATED_SECONDS_PER_WRITE_BATCH).round(2)
  end

  # ── Write ────────────────────────────────────────────────────────────

  def write!(changes)
    return if changes.empty?

    changes.each_slice(WRITE_BATCH_SIZE) do |slice|
      ActiveRecord::Base.transaction do
        slice.each do |c|
          ShoplineOrder.where(id: c[:id]).update_all(source_row_hash: c[:new_hash]) # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end
  end

  # 寫入後重新掃描一次確認：不再有待處理的變更、也沒有新的 collision。
  def verify(plan)
    post = build_plan
    {
      rows_still_pending: post[:changes].size,
      collisions_after_apply: post[:collisions].size,
      clean: post[:changes].empty? && post[:collisions].empty?
    }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
