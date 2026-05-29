class GlutathioneAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_sql        = "product_name LIKE '%穀胱甘肽%'"
  self.product_label      = "穀胱甘肽"
  self.product_regex      = /穀胱甘肽(\d+)/
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("穀胱甘肽") }.freeze

  def index
    @all_glut_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_glut_events)
  end

  private

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(product_regex)
    return m[1].to_i if m
    m = product_name.match(/[（(](\d+)[瓶盒]/)
    return m[1].to_i if m
    return 6 if product_name.include?("家庭號")
    1
  end
end
