class ProbioticAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_sql        = "product_name LIKE '%益生菌%'"
  self.product_label      = "益生菌"
  self.product_regex      = /益生菌(\d+)/
  PROBIOTIC_EVENT_DATES = [Date.new(2026, 2, 6), Date.new(2026, 3, 20)].freeze

  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| PROBIOTIC_EVENT_DATES.include?(e[:date]) }.freeze

  def index
    @all_probiotic_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_probiotic_events)
  end

  private

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(product_regex)
    return m[1].to_i if m
    m = product_name.match(/[（(](\d+)[瓶盒]/)
    return m[1].to_i if m
    1
  end
end
