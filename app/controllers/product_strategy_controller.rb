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

    # 上方概覽卡片也用同一份結果表（不含「其他」）
    rows = @cohort_rows.except(CustomerCohortStatsRefreshService::OTHER).values
    total = rows.sum { |r| r[:total] }
    eligible = @cohort_rows.except(CustomerCohortStatsRefreshService::OTHER).select { |_, r| r[:total] >= 50 }
    @overview = {
      total_customers: @cohort_total,
      return_rate: total.positive? ? (rows.sum { |r| r[:repurchased] } * 100.0 / total).round(1) : 0.0,
      silent: rows.sum { |r| r[:silent] },
      watching: rows.sum { |r| r[:watching] },
      upgraded: @cohort_rows.values.sum { |r| r[:upgraded] },
      best_retention: eligible.max_by { |_, r| r[:repurchased].to_f / r[:total] }
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

    # 首購期間只列這個產品有首購客人的年份（例如 PDRN 預購 2026 才開賣，就不列 2024／2025）
    years = CustomerCohortStat.where(source: @source).distinct.pluck(Arel.sql("EXTRACT(YEAR FROM first_date)::int")).map(&:to_s)
    @period_options = CustomerCohortStatsQuery::PERIODS.select { |k, _| k.blank? || k == "180" || years.include?(k) || k == @period }

    @status = STATUS_FILTERS.key?(params[:status].to_s) ? params[:status].to_s : ""
    @sort = SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "after_amount"
    list = query.scope.where(source: @source)
    list = list.where(STATUS_FILTERS[@status]) if @status.present?

    # 跨買排行：之後買過（cross）或第二筆訂單（second）買了某產品
    # 預設看「第二筆訂單買什麼」，rank=after 看首購後任何時候買過的其他產品
    @rank_mode = params[:rank] == "after" ? "after" : "second"
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
end
