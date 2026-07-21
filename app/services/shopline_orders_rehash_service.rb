# frozen_string_literal: true

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
# whether or not the pattern-A dedupe cleanup has already happened. Running
# dedupe first is still recommended (fewer stale rows to carry forward, and
# it removes the orphaned NULL-total_amount row entirely) but not a hard
# requirement.
#
# Occurrence MUST be computed over the whole table in one pass, not batch by
# batch — find_in_batches groups by primary key only, so if a duplicate-
# signature group straddled a batch boundary, restarting the counter at 1 in
# the second batch would collide two unrelated rows onto the same hash. All
# ~42k rows are plucked into memory for the compute pass (a few MB, in line
# with existing full-period plucks elsewhere in this codebase); only the
# WRITE phase is batched.
class ShoplineOrdersRehashService
  WRITE_BATCH_SIZE = 2_000

  def self.call(apply: false)
    new(apply: apply).call
  end

  def initialize(apply: false)
    @apply = apply
  end

  def call
    changes = compute_changes
    apply!(changes) if @apply

    { total_rows: ShoplineOrder.count, rows_to_rehash: changes.size, applied: @apply }
  end

  private

  def compute_changes
    rows = ShoplineOrder
      .order(:order_number, :product_name, :quantity, :checkout_amount, :id)
      .pluck(:id, :order_number, :product_name, :quantity, :checkout_amount, :source_row_hash)

    occurrence_counts = Hash.new(0)
    changes = []

    rows.each do |id, order_number, product_name, quantity, checkout_amount, old_hash|
      signature = [
        order_number,
        ShoplineOrder.normalize_product_name(product_name),
        quantity.to_i,
        ShoplineOrder.format_decimal(checkout_amount)
      ]
      occurrence_counts[signature] += 1

      new_hash = ShoplineOrder.content_hash(
        order_number: order_number, product_name: product_name,
        quantity: quantity, checkout_amount: checkout_amount,
        occurrence: occurrence_counts[signature]
      )
      changes << { id: id, old_hash: old_hash, new_hash: new_hash } if new_hash != old_hash
    end

    changes
  end

  def apply!(changes)
    return if changes.empty?

    changes.each_slice(WRITE_BATCH_SIZE) do |slice|
      ActiveRecord::Base.transaction do
        slice.each do |c|
          ShoplineOrder.where(id: c[:id]).update_all(source_row_hash: c[:new_hash]) # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end
  end
end
