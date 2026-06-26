class MetabolismAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "metabolism"
  self.product_sql        = "product_name LIKE '%代謝%'"
  self.product_label      = "代謝錠"
  self.product_regex      = /代謝錠?(\d+)/
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("代謝") }.freeze

  def index
    @all_meta_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_meta_events)
  end

  private

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    return 6 if product_name.include?("家庭號")
    m = product_name.match(product_regex)
    base = if m
      m[1].to_i
    elsif (m2 = product_name.match(/[（(](\d+)[瓶盒]/))
      m2[1].to_i
    else
      1
    end
    base + (product_name.match(/送(\d+)/)&.[](1).to_i || 0)
  end
end
