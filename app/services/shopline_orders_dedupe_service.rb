# frozen_string_literal: true

# Safe cleanup for the "pattern A" duplicate rows discovered in Phase 0A:
# the same real order line, re-exported by Shopline across two different
# import runs, where total_amount is populated in the older import and NULL
# in the newer one — because total_amount used to be part of source_row_hash,
# find_or_initialize_by inserted a second row instead of updating the first.
#
# Only a group that matches ALL of the following is a pattern-A candidate:
#   - exactly 2 rows share (order_number, product_name, checkout_amount, quantity)
#   - exactly one of the two has total_amount IS NOT NULL, the other IS NULL
#   - the two rows come from different import_run_id
#   - email and order_date also match between the two (defensive: order_number
#     already embeds a timestamp and should make this a formality, but a
#     destructive operation re-checks rather than assumes)
#
# Everything else — 3+ rows in a group, both-NULL / both-present total_amount,
# same import_run_id, mismatched email/order_date — is left completely alone
# ("pattern B/C") and counted under skipped_reasons. dry_run never writes.
# apply always re-runs group discovery itself (never accepts an externally
# passed id list, so a stale dry-run snapshot can't be replayed blindly),
# wraps the whole batch in one transaction, backs up every row it is about
# to delete into shopline_orders_dedupe_backups first, and takes a Postgres
# advisory lock so two dedupe runs can't step on each other (this does NOT
# by itself block a concurrently-running import — see the deployment runbook
# for why apply is scheduled outside the import window instead).
class ShoplineOrdersDedupeService
  LOCK_NAME = "shopline_orders_dedupe"

  Candidate = Struct.new(:keep_id, :delete_id, :order_number, :product_name,
                        :quantity, :checkout_amount, :email, keyword_init: true)

  def self.call(apply: false)
    new(apply: apply).call
  end

  def initialize(apply: false)
    @apply = apply
    @run_id = SecureRandom.uuid
  end

  def call
    with_advisory_lock do
      candidates, skipped_reasons = discover
      report = build_report(candidates, skipped_reasons)

      if @apply
        delete!(candidates)
        report[:applied] = true
        report[:dedupe_run_id] = @run_id
        report[:verification] = verify_after_apply(candidates)
      else
        report[:applied] = false
      end

      report
    end
  end

  private

  def with_advisory_lock
    conn = ActiveRecord::Base.connection
    lock_key = conn.quote(LOCK_NAME)
    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{lock_key}))")
    )
    unless acquired
      return { group_count: 0, applied: false, aborted: true,
                abort_reason: "lock_busy — another dedupe run is in progress" }
    end

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{lock_key}))")
    end
  end

  # ── Discovery (always re-run fresh; apply never trusts a cached list) ──

  def discover
    groups = ShoplineOrder
      .group(:order_number, :product_name, :checkout_amount, :quantity)
      .having("COUNT(*) > 1")
      .pluck(:order_number, :product_name, :checkout_amount, :quantity, Arel.sql("array_agg(id)"))

    candidates = []
    skipped_reasons = Hash.new(0)

    groups.each do |order_number, product_name, checkout_amount, quantity, ids|
      if ids.size != 2
        skipped_reasons["group_size_not_2 (#{ids.size} rows)"] += 1
        next
      end

      rows = ShoplineOrder.where(id: ids).order(:id).to_a
      a, b = rows

      candidate = classify_pair(a, b, order_number, product_name, quantity, checkout_amount)
      if candidate
        candidates << candidate
      else
        skipped_reasons[skip_reason_for(a, b)] += 1
      end
    end

    [candidates, skipped_reasons]
  end

  def classify_pair(a, b, order_number, product_name, quantity, checkout_amount)
    present, blank = if a.total_amount.present? && b.total_amount.blank?
      [a, b]
    elsif b.total_amount.present? && a.total_amount.blank?
      [b, a]
    end
    return nil unless present # both present or both blank — not pattern A

    return nil if present.import_run_id == blank.import_run_id # same batch — not pattern A
    return nil if present.email != blank.email                  # defensive core-field check
    return nil if present.order_date != blank.order_date

    Candidate.new(keep_id: present.id, delete_id: blank.id, order_number: order_number,
                 product_name: product_name, quantity: quantity, checkout_amount: checkout_amount,
                 email: present.email)
  end

  def skip_reason_for(a, b)
    return "both_total_amount_present" if a.total_amount.present? && b.total_amount.present?
    return "both_total_amount_blank"   if a.total_amount.blank? && b.total_amount.blank?

    present = a.total_amount.present? ? a : b
    blank   = a.total_amount.present? ? b : a
    return "same_import_run"      if present.import_run_id == blank.import_run_id
    return "core_fields_mismatch"

    "unclassified"
  end

  # ── Report (aggregate counts only — no names/emails/phones in output) ──

  def build_report(candidates, skipped_reasons)
    {
      group_count: candidates.size + skipped_reasons.values.sum,
      candidate_delete_count: candidates.size,
      retained_count: candidates.size,
      skipped_count: skipped_reasons.values.sum,
      skipped_reasons: skipped_reasons,
      affected_customers: candidates.map(&:email).uniq.compact.size,
      affected_orders: candidates.map(&:order_number).uniq.size,
      per_product: per_product_breakdown(candidates),
      amount_impact: {
        # 這是「修正」不是「損失」：被刪除的列與保留的列 checkout_amount 相同，
        # 任何逐列 SUM(checkout_amount) 的營收聚合過去把這筆金額算了兩次；
        # 刪除後該類聚合會下降這個總額，屬於雙重計算的修正。
        checkout_amount_double_counted: candidates.sum { |c| c.checkout_amount.to_d }
      }
    }
  end

  def per_product_breakdown(candidates)
    patterns = JourneyProducts::PRODUCTS.transform_values { |p| like_to_regex(p[:sql]) }
    candidates.group_by do |c|
      patterns.find { |_key, re| c.product_name.to_s.match?(re) }&.first || "unmatched"
    end.transform_values(&:size)
  end

  def like_to_regex(like_sql)
    keyword = like_sql[/LIKE '%(.+)%'/, 1]
    /#{Regexp.escape(keyword)}/
  end

  # ── Apply ────────────────────────────────────────────────────────────

  def delete!(candidates)
    return if candidates.empty?

    ActiveRecord::Base.transaction do
      candidates.each_slice(500) do |slice|
        rows = ShoplineOrder.where(id: slice.map(&:delete_id)).index_by(&:id)

        backup_attrs = slice.map do |c|
          row = rows.fetch(c.delete_id)
          {
            original_id: row.id, kept_id: c.keep_id, dedupe_run_id: @run_id,
            order_number: row.order_number, product_name: row.product_name,
            quantity: row.quantity, checkout_amount: row.checkout_amount,
            total_amount: row.total_amount, email: row.email, order_date: row.order_date,
            import_run_id: row.import_run_id, created_at: Time.current
          }
        end
        ShoplineOrdersDedupeBackup.insert_all!(backup_attrs)

        ShoplineOrder.where(id: slice.map(&:delete_id)).delete_all
      end
    end
  end

  # 刪除完成後重新掃描一次，確認「模式 A 剩餘數為 0 或合理 skipped」，
  # 並回報訂單數變化是否與 candidate_delete_count 一致。
  def verify_after_apply(candidates)
    remaining_candidates, remaining_skipped = discover
    {
      pattern_a_remaining: remaining_candidates.size,
      remaining_skipped_reasons: remaining_skipped,
      deleted_row_count: candidates.size,
      kept_ids_still_present: ShoplineOrder.where(id: candidates.map(&:keep_id)).count == candidates.map(&:keep_id).uniq.size,
      deleted_ids_gone: ShoplineOrder.where(id: candidates.map(&:delete_id)).count.zero?
    }
  end
end
