class MetabolismAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "metabolism"
  self.product_label      = "代謝錠"
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("代謝") }.freeze

  def index
    @all_meta_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_meta_events)
  end
end
