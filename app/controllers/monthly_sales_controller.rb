# app/controllers/monthly_sales_controller.rb
class MonthlySalesController < ApplicationController
  YEARS = [2024, 2025, 2026].freeze

  def index
    @years = YEARS
    revenue_col = revenue_column_sql # => "checkout_amount" or "total_amount"

    rows = ShoplineOrder
      .where(source_year: @years)
      .where.not(source_month: nil)
      .group(:source_year, :source_month)
      .select(
        "source_year",
        "source_month",
        "COALESCE(SUM(#{revenue_col}), 0) AS revenue"
      )

    @chart = build_revenue_chart(rows)
  end

  private

  def revenue_column_sql
    ShoplineOrder.column_names.include?("checkout_amount") ? "checkout_amount" : "total_amount"
  end

  def build_revenue_chart(rows)
    labels = (1..12).map { |m| "#{m}月" }
    matrix = YEARS.index_with { Array.new(12, 0) }

    rows.each do |r|
      y = r.source_year.to_i
      m = r.source_month.to_i
      next unless matrix.key?(y) && (1..12).cover?(m)
      matrix[y][m - 1] = r.revenue.to_f.round(0).to_i
    end

    { labels: labels, series: YEARS.map { |y| { name: y.to_s, data: matrix[y] } } }
  end
end
