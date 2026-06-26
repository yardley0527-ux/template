class GlutathioneAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "glutathione"  # Epic C Phase 2: Registry-driven (+29 rows vs LIKE = typo spellings now included ✓)
  self.product_label      = "穀胱甘肽"
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("穀胱甘肽") }.freeze

  def index
    @all_glut_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_glut_events)
  end
end
