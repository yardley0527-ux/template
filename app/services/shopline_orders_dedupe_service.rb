# frozen_string_literal: true

require Rails.root.join("lib/shopline_orders_maintenance_lock") if defined?(Rails)

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
# to delete into shopline_orders_dedupe_backups first, and takes the shared
# ShoplineOrdersMaintenanceLock (also held by the importer and by
# ShoplineOrdersRehashService#apply) so none of the three can run at the
# same time as another.
class ShoplineOrdersDedupeService
  Candidate = Struct.new(:keep_id, :delete_id, :order_number, :product_name,
                        :quantity, :checkout_amount, :email, :order_date, :deleted_total_amount,
                        keyword_init: true)

  def self.call(apply: false)
    new(apply: apply).call
  end

  def initialize(apply: false)
    @apply = apply
    @run_id = SecureRandom.uuid
  end

  def call
    return dry_run_report unless @apply

    acquired, result = ShoplineOrdersMaintenanceLock.try_with_lock { run_apply }
    return result if acquired

    { group_count: 0, applied: false, aborted: true,
      abort_reason: "lock_busy — the importer or another rehash/dedupe run holds " \
                    "#{ShoplineOrdersMaintenanceLock::NAME}" }
  end

  private

  def dry_run_report
    candidates, skipped_reasons = discover
    build_report(candidates, skipped_reasons).merge(applied: false)
  end

  def run_apply
    candidates, skipped_reasons = discover # re-run fresh, even though only used for apply here
    report = build_report(candidates, skipped_reasons)

    delete!(candidates)
    report[:applied] = true
    report[:dedupe_run_id] = @run_id
    report[:verification] = verify_after_apply(candidates)

    report
  end

  # ── Discovery (always re-run fresh; apply never trusts a cached list) ──

  def discover
    groups = ShoplineOrder
      .group(:order_number, :product_name, :checkout_amount, :quantity)
      .having("COUNT(*) > 1")
      .pluck(:order_number, :product_name, :checkout_amount, :quantity, Arel.sql("array_agg(id)"))

    candidates = []
    skipped_reasons = Hash.new(0)
    two_row_groups = []

    groups.each do |order_number, product_name, checkout_amount, quantity, ids|
      if ids.size != 2
        skipped_reasons["group_size_not_2 (#{ids.size} rows)"] += 1
      else
        two_row_groups << [order_number, product_name, checkout_amount, quantity, ids]
      end
    end

    # 一次把所有候選組的列都撈出來，避免每組各查一次（production 規模下
    # 是 1,000+ 組，逐組查會是 1,000+ 次往返）。
    all_ids = two_row_groups.flat_map { |group| group.last }
    rows_by_id = all_ids.empty? ? {} : ShoplineOrder.where(id: all_ids).index_by(&:id)

    two_row_groups.each do |order_number, product_name, checkout_amount, quantity, ids|
      a, b = ids.map { |id| rows_by_id.fetch(id) }

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
                 email: present.email, order_date: present.order_date,
                 deleted_total_amount: blank.total_amount)
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
      row_count_change: {
        shopline_orders: -candidates.size
      },
      amount_impact: amount_impact(candidates),
      revenue_impact_by_year: revenue_by_period(candidates) { |d| d.year.to_s },
      revenue_impact_by_month: revenue_by_period(candidates) { |d| d.strftime("%Y-%m") },
      cache_impact: cache_impact(candidates)
    }
  end

  # amount_impact 明確區分「已證實會被修正的雙重計算」與「已證實不受影響」：
  # - checkout_amount_sum_removed：被刪除列的 checkout_amount 加總。這個金額
  #   目前確實被逐列（非依 order_number 去重）加總的聚合重複計算一次，例如
  #   CrmProductMonthlyStatsRefreshService#natural_revenue（app/services/
  #   crm_product_monthly_stats_refresh_service.rb 對 shopline_orders 直接
  #   SUM(checkout_amount) GROUP BY 月份+產品，未依 order_number 去重）與
  #   SpendingRankingsReport 的「各系列消費」明細（GROUP BY email,
  #   product_name，未依 order_number 去重）。清理後這兩處的數字會下降這個
  #   金額——這是修正，不是營收損失：保留的那一列本來就已經算過一次同樣的
  #   金額。
  # - total_amount_sum_removed：被刪除列的 total_amount 一定是 NULL（模式 A
  #   的定義本身），所以恆為 0。任何以 total_amount／MAX(total_amount) GROUP
  #   BY order_number 為基礎的聚合（CustomerPurchaseSummaryRefreshService、
  #   SpendingRankingsReport 的排行本身、Analytics::ProductAnalysis 的
  #   sum(:total_amount)）完全不受本次清理影響——這裡回傳 0 是實際算出來的
  #   結果，不是假設。
  def amount_impact(candidates)
    {
      checkout_amount_sum_removed: candidates.sum { |c| c.checkout_amount.to_d },
      # 用「刪除列的實際 total_amount」加總，不是假設 0——只是模式 A 的定義
      # 本身保證這個值一定是 nil/0（分類邏輯只選出 total_amount 為空的那一
      # 列刪除），所以這裡算出來的結果會是 0，證明而非假設。
      total_amount_sum_removed: candidates.sum { |c| c.deleted_total_amount.to_d }
    }
  end

  def revenue_by_period(candidates)
    candidates.group_by { |c| yield(c.order_date) }
              .transform_values { |cs| cs.sum { |c| c.checkout_amount.to_d } }
              .sort.to_h
  end

  # 只回報「有多少候選客戶的 email 同時出現在這些快取表裡」（純計數，不含
  # 個資），標明哪些表已證實不受影響、哪些建議 refresh 但屬於衛生性重算
  # （因為 refresh 本身冪等、成本低，即使數字不變也不影響正確性）。
  def cache_impact(candidates)
    emails = candidates.map(&:email).uniq.compact
    {
      customer_purchase_summaries_customers_present:
        emails.empty? ? 0 : CustomerPurchaseSummary.where(email: emails).count,
      customer_series_loyalties_customers_present:
        emails.empty? ? 0 : CustomerSeriesLoyalty.where(email: emails).count,
      notes: {
        customer_purchase_summaries: "order_amount 用 MAX(total_amount) GROUP BY order_number 計算，" \
                                     "已證實不受本次清理影響（見 total_amount_sum_removed=0）；" \
                                     "建議仍列入 refresh 排程作為衛生性重算，非必要修正",
        customer_series_loyalties: "同上（金額估算邏輯不依賴逐列 checkout_amount 加總方式）",
        spending_rankings: "排行榜本身（Top100/200 依 order-level 金額）不受影響；" \
                           "系列別消費明細（GROUP BY email,product_name，未去重 order_number）" \
                           "會反映本次修正，屬即時查詢頁面，無需額外 refresh",
        livestream_d0_d3_attribution: "LivestreamAnalysisController 目前讀寫在程式碼內的固定歷史陣列，" \
                                      "不查詢 shopline_orders，不受本次清理影響"
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
