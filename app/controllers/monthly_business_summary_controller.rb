class MonthlyBusinessSummaryController < ApplicationController
  def index
    @years = MonthlyBusinessSummaryAnalytics.available_years
    @years = [Date.current.year] if @years.blank?
    @year  = params[:year].presence&.to_i || @years.max

    analytics = MonthlyBusinessSummaryAnalytics.new(@year)
    @overview_rows  = analytics.overview_rows
    @breakdown_rows = analytics.breakdown_rows
  end
end
