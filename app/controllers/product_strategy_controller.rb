# frozen_string_literal: true

class ProductStrategyController < ApplicationController
  PER_PAGE = 50

  # 各產品分析名單的排序（SQL ORDER BY）
  SORTS = {
    "after_amount" => "after_amount DESC, first_amount DESC",
    "first_amount" => "first_amount DESC, after_amount DESC",
    "first_date" => "first_date DESC, first_amount DESC",
    "last_order" => "last_order_date DESC, after_amount DESC"
  }.freeze

  # 距上次購買天數
  RECENCY = {
    "0_30" => [0, 30], "31_60" => [31, 60], "61_90" => [61, 90], "91_180" => [91, 180], "181" => [181, nil]
  }.freeze

  STATUS_FILTERS = {
    "repurchased" => "after_days > 0",
    "not_yet" => "after_days = 0",
    "same_again" => "same_again",
    "only_same" => "same_again AND CARDINALITY(cross_families) = 0",
    "cross" => "CARDINALITY(cross_families) > 0",
    "upgraded" => "upgraded"
  }.freeze

  def index
    # 首購來源追蹤總表：讀 customer_cohort_stats（匯入訂單後在資料庫裡重算），不在 web 程序算
    @cohort_query = CustomerCohortStatsQuery.new(period: params[:period])
    @period = @cohort_query.period
    @cohort_rows = @cohort_query.overview
    @cohort_total = @cohort_rows.values.sum { |v| v[:total] }
    @cohort_refreshed_at = @cohort_query.refreshed_at

    @report = Rails.cache.fetch("product_strategy:report:v3", expires_in: 1.hour) do
      build_report
    end

    # 平均回購率只算有首購資料的系列，剛納入分析的新產品（total 0）不稀釋整體數字
    with_data = @report.select { |r| r[:total].positive? }

    @overview = {
      total_customers:  @report.sum { |r| r[:total] },
      avg_return_rate:  with_data.any? ? (with_data.sum { |r| r[:return_rate] }.to_f / with_data.size).round(1) : 0.0,
      total_silent:     @report.sum { |r| r[:silent].to_i + r[:watching].to_i },
      total_iron:       @report.sum { |r| r[:iron] },
      best_retention:   with_data.max_by { |r| r[:return_rate] }
    }
  end

  def show
    @source = params[:source].to_s
    unless CustomerCohortStatsRefreshService.sources.include?(@source)
      redirect_to product_strategy_path, alert: "找不到這個首購來源" and return
    end
    query = CustomerCohortStatsQuery.new(period: params[:period])
    @period = query.period
    @summary = query.summary(@source)

    @status = STATUS_FILTERS.key?(params[:status].to_s) ? params[:status].to_s : ""
    @sort = SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "after_amount"
    list = query.scope.where(source: @source)
    list = list.where(STATUS_FILTERS[@status]) if @status.present?

    # 跨買排行：之後買過（cross）或第二筆訂單（second）買了某產品
    @rank_mode = params[:rank] == "second" ? "second" : "after"
    @product = params[:product].to_s
    @product = "" unless CustomerCohortStatsRefreshService::FAMILY_PATTERNS.map(&:first).include?(@product)
    if @product.present?
      col = @rank_mode == "second" ? "second_families" : "cross_families"
      list = list.where("? = ANY(#{col})", @product)
    end

    @recency = RECENCY.key?(params[:recency].to_s) ? params[:recency].to_s : ""
    if @recency.present?
      lo, hi = RECENCY[@recency]
      list = list.where("last_order_date <= ?", Date.current - lo)
      list = list.where("last_order_date >= ?", Date.current - hi) if hi
    end
    @total = list.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @offset = (@page - 1) * PER_PAGE
    @people = list.order(Arel.sql(SORTS[@sort])).offset(@offset).limit(PER_PAGE).to_a
  end

  # 手動重算首購產品分析（平常匯入訂單後會自動重算）
  def refresh_cohorts
    RefreshCustomerCohortStatsJob.perform_later
    redirect_to product_strategy_path, notice: "已開始重新計算首購產品分析，約 1 分鐘後重新整理頁面"
  end

  private

  # crm_products 剛納入分析、summaries 還沒有該系列首購資料時的空白列，
  # 缺任何一個鍵都會讓 index 的加總 500
  EMPTY_SERIES_STAT = {
    total: 0, returned: 0, silent: 0, watching: 0,
    return_rate: 0.0, avg_first: 0, threshold: 0
  }.freeze

  # PDRN 拆成預購／現貨（首購品名「預購」開頭），跟客人資料庫的首購來源一致
  FIRST_SOURCE_SQL = "CASE WHEN first_series = 'PDRN' THEN (CASE WHEN first_product LIKE '預購%' THEN 'PDRN 預購' ELSE 'PDRN 現貨' END) ELSE first_series END"

  def build_report
    # 各系列基本統計
    series_stats = CustomerPurchaseSummary
      .where.not(first_series: nil)
      .group(Arel.sql(FIRST_SOURCE_SQL))
      .pluck(
        Arel.sql(FIRST_SOURCE_SQL),
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN silent_only = TRUE THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN purchase_count = 1 AND silent_only = FALSE THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(first_amount)::numeric(10,0)"),
        Arel.sql("MAX(silent_days_threshold)")
      ).map do |series, total, returned, silent, watching, avg_first, threshold|
        return_rate = total.to_i.zero? ? 0.0 : (returned.to_f / total * 100).round(1)
        {
          series:      series,
          total:       total.to_i,
          returned:    returned.to_i,
          silent:      silent.to_i,
          watching:    watching.to_i,
          return_rate: return_rate,
          avg_first:   avg_first.to_i,
          threshold:   threshold.to_i
        }
      end.index_by { |r| r[:series] }

    # 忠實客 / 鐵粉數
    loyalty_stats = CustomerSeriesLoyalty
      .group(:series)
      .pluck(
        :series,
        Arel.sql("SUM(CASE WHEN tier = '忠實客' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN tier = '鐵粉'  THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(order_count)::numeric(10,1)")
      ).map do |series, loyal, iron, avg_count|
        [series, { loyal: loyal.to_i, iron: iron.to_i, avg_count: avg_count.to_f.round(1) }]
      end.to_h

    # PDRN 的忠實客／鐵粉依該客人首購是預購還是現貨拆開（首購不是 PDRN 的 PDRN 回購客不列入這兩列）
    CustomerSeriesLoyalty
      .joins("JOIN customer_purchase_summaries cps ON cps.email = customer_series_loyalties.email AND cps.first_series = 'PDRN'")
      .where(series: "PDRN")
      .group(Arel.sql("CASE WHEN cps.first_product LIKE '預購%' THEN 'PDRN 預購' ELSE 'PDRN 現貨' END"))
      .pluck(
        Arel.sql("CASE WHEN cps.first_product LIKE '預購%' THEN 'PDRN 預購' ELSE 'PDRN 現貨' END"),
        Arel.sql("SUM(CASE WHEN customer_series_loyalties.tier = '忠實客' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN customer_series_loyalties.tier = '鐵粉'  THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(customer_series_loyalties.order_count)::numeric(10,1)")
      ).each do |source, loyal, iron, avg_count|
        loyalty_stats[source] = { loyal: loyal.to_i, iron: iron.to_i, avg_count: avg_count.to_f.round(1) }
      end

    # 第二購方向（排除同系列回購，只看跨系列導流）
    second_purchase = CustomerPurchaseSummary
      .where.not(first_series: nil, second_series: nil)
      .where("second_series <> '' AND second_series <> first_series")
      .group(Arel.sql(FIRST_SOURCE_SQL), :second_series)
      .count
      .group_by { |(first, _second), _count| first }
      .transform_values do |pairs|
        total = pairs.sum { |_k, count| count }.to_f
        pairs.map { |((_first, second), count)| [second, (count / total * 100).round(1)] }
             .sort_by { |(_s, pct)| -pct }
             .first(3)
      end

    CrmProduct.series_labels_for_filter.flat_map { |s| s == "PDRN" ? ["PDRN 預購", "PDRN 現貨"] : [s] }.map do |series|
      stat    = series_stats[series] || EMPTY_SERIES_STAT
      loyalty = loyalty_stats[series] || { loyal: 0, iron: 0, avg_count: 0 }
      second  = second_purchase[series] || []

      stat.merge(
        series:           series,
        loyal:            loyalty[:loyal],
        iron:             loyalty[:iron],
        avg_count:        loyalty[:avg_count],
        second_purchases: second,
        watching:         stat[:watching].to_i
      )
    end
  end
end