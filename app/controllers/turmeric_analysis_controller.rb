# frozen_string_literal: true

class TurmericAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_sql        = "product_name LIKE '%薑黃%'"
  self.product_label      = "薑黃"
  self.product_regex      = /薑黃(\d+)/
  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("薑黃") }.freeze

  def index
    @all_turmeric_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_turmeric_events)
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
