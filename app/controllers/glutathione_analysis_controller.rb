class GlutathioneAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "glutathione"  # Epic C Phase 2: Registry-driven (+29 rows vs LIKE = typo spellings now included ✓)
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
