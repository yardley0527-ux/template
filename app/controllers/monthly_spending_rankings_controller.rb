# frozen_string_literal: true

# 月消費排行榜：選一個月份，看該月已付款金額前 100 名，可切「全部 / 新客 / 舊客」。
# 新客＝第一筆已付款訂單（以 email 判定）落在該月；舊客＝該月以前就買過。
# 口徑與計算都在 SpendingRankingsReport#monthly_ranking，這裡只處理參數與名次。
class MonthlySpendingRankingsController < ApplicationController
  FIRST_MONTH = Date.new(2025, 1, 1)
  LIMIT = 100
  TYPES = { "all" => "全部", "new" => "新客", "old" => "舊客" }.freeze

  def index
    this_month = Date.current.beginning_of_month
    @month = parse_month(params[:month]) || this_month
    @month = this_month if @month > this_month
    @month = FIRST_MONTH if @month < FIRST_MONTH
    @prev_month = @month > FIRST_MONTH ? @month.prev_month : nil
    @next_month = @month < this_month ? @month.next_month : nil
    @month_options = (FIRST_MONTH..this_month).select { |d| d.day == 1 }.reverse
    @type = TYPES.key?(params[:type]) ? params[:type] : "all"

    result = SpendingRankingsReport.new.monthly_ranking(@month, limit: LIMIT)
    everyone = result[:all_rows]
    new_rows = everyone.select { |t| t[:new_customer] }
    old_rows = everyone.reject { |t| t[:new_customer] }

    @summary = {
      total_amount: result[:total_amount], buyer_count: result[:buyer_count], order_count: result[:order_count],
      new_amount: new_rows.sum { |t| t[:amount] }, new_count: new_rows.size,
      old_amount: old_rows.sum { |t| t[:amount] }, old_count: old_rows.size,
      top_amount: result[:top_amount]
    }

    segment = { "all" => everyone, "new" => new_rows, "old" => old_rows }[@type]
    # 新客／舊客榜在各自群體內重新編名次
    @rows = segment.first(LIMIT).each_with_index.map { |t, i| t.merge(rank: i + 1) }
    snapshots = SpendingRankingsReport.new.customer_snapshots(@rows.map { |t| t[:email] })
    @rows = @rows.map { |t| t.merge(snapshot: snapshots[t[:email]] || {}) }
  end

  private

  def parse_month(str)
    return nil unless str.to_s.match?(/\A\d{4}-\d{2}\z/)

    Date.strptime(str, "%Y-%m")
  rescue ArgumentError
    nil
  end
end
