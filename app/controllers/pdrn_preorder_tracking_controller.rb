# frozen_string_literal: true

# PDRN 預購客追蹤頁：持續看買過 PDRN 預購的客人後續回購、跨買、卡別變化。
# 資料由 PdrnPreorderTracking 從訂單即時算（每次匯入訂單後快取自動失效）。
class PdrnPreorderTrackingController < ApplicationController
  PER_PAGE = 50

  SORTS = {
    "pre_amount" => ->(p) { [-p[:pre_amount], -p[:after_amount]] },
    "after_amount" => ->(p) { [-p[:after_amount], -p[:pre_amount]] },
    "last_order" => ->(p) { [-p[:last_order_date].jd, -p[:after_amount]] },
    "first_pre" => ->(p) { [-p[:first_pre_date].jd, -p[:pre_amount]] }
  }.freeze

  def index
    data = PdrnPreorderTracking.call
    @summary = data[:summary]
    @excluded_names = data[:excluded_names]
    @data_until = data[:data_until]

    @segment = params[:segment].to_s
    @status = params[:status].to_s
    @sort = SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "pre_amount"

    people = data[:people]
    people = people.select { |p| p[:new_customer] } if @segment == "new"
    people = people.reject { |p| p[:new_customer] } if @segment == "old"
    people = people.select { |p| p[:after_days].positive? } if @status == "repurchased"
    people = people.select { |p| p[:after_days].zero? } if @status == "not_yet"
    people = people.select { |p| p[:cross].any? } if @status == "cross"
    people = people.select { |p| p[:upgraded] } if @status == "upgraded"
    sorted = people.sort_by(&SORTS[@sort])
    @total = sorted.size
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @offset = (@page - 1) * PER_PAGE
    @people = sorted.slice(@offset, PER_PAGE) || []
  end
end
