class MonthlyBusinessSummaryController < ApplicationController
  OVERVIEW_HIGHLIGHT_KEYS = %i[
    net_amount paid_order_count total_customers
    avg_order_amount repurchase_rate new_member_count
  ].freeze

  BREAKDOWN_HIGHLIGHT_KEYS = %i[
    total_customers new_count new_revenue new_avg_amount
    old_count old_revenue old_avg_amount new_old_ratio
    new_repeat_count new_repeat_revenue
  ].freeze

  def index
    years = MonthlyBusinessSummaryAnalytics.available_years
    years = [Date.current.year] if years.blank?

    @overview_rows  = years.flat_map { |y| MonthlyBusinessSummaryAnalytics.new(y).overview_rows }.sort_by { |r| r[:month] }
    @breakdown_rows = years.flat_map { |y| MonthlyBusinessSummaryAnalytics.new(y).breakdown_rows }.sort_by { |r| r[:month] }

    @overview_best  = best_indices(@overview_rows, OVERVIEW_HIGHLIGHT_KEYS)
    @breakdown_best = best_indices(@breakdown_rows, BREAKDOWN_HIGHLIGHT_KEYS)
  end

  private

  def best_indices(rows, keys)
    keys.index_with do |key|
      values = rows.each_with_index.filter_map { |row, i| [row[key], i] if row[key] }
      values.max_by(&:first)&.last
    end
  end
end
