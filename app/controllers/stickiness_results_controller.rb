# 黏著度成效：已追蹤（有填黏著度備註）的客人，確認追蹤後是否回購同系列，
# 依客人類型＋卡別分類並統計成效
class StickinessResultsController < ApplicationController
  include StickinessScoping

  def index
    @tab        = %w[repurchased pending].include?(params[:tab]) ? params[:tab] : 'repurchased'
    @start_date = parse_date(params[:start_date])
    @end_date   = parse_date(params[:end_date]) || @start_date
    @end_date   = @start_date if @start_date && @end_date && @end_date < @start_date

    rows = build_rows.select(&:tracked?)

    # 日期區間篩選「追蹤日期」
    if @start_date.present?
      rows = rows.select do |r|
        at = r.profile.stickiness_followed_up_at
        at && at >= @start_date.beginning_of_day && at <= @end_date.end_of_day
      end
    end

    repurchased, pending = rows.partition { |r| r.repurchases.any? }
    @repurchased_count = repurchased.size
    @pending_count     = pending.size
    @stats             = build_stats(rows, repurchased)

    @groups = group_by_customer_type(@tab == 'repurchased' ? repurchased : pending)
  end

  private

  def build_stats(rows, repurchased)
    tracked = rows.size
    days    = repurchased.map { |r| r.repurchases.map { |rep| rep[:days_between] }.min }
    revenue = repurchased.flat_map(&:repurchases)
                         .uniq { |rep| rep[:order_number] }
                         .sum { |rep| rep[:amount] }
    {
      tracked:     tracked,
      repurchased: repurchased.size,
      rate:        tracked.zero? ? nil : (repurchased.size * 100.0 / tracked).round(1),
      avg_days:    days.empty? ? nil : (days.sum.to_f / days.size).round(1),
      revenue:     revenue,
    }
  end
end
