# frozen_string_literal: true

class TurmericAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_key        = "turmeric"
  self.product_sql        = "product_name LIKE '%薑黃%'"
  self.product_label      = "薑黃"
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("薑黃") }.freeze

  def index
    @all_turmeric_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_turmeric_events)
  end
end
