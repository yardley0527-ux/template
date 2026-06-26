# frozen_string_literal: true

class TurmericAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  # TODO Epic C Phase 3: set product_key = "turmeric" once bundle SKUs
  # (代謝錠1薑黃1, 薑黃4全能3, etc. — 39 multi-product names) are resolved
  # with multi-product mapping support. Currently -6,327 rows vs LIKE if switched.
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
