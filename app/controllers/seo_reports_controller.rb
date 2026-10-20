# frozen_string_literal: true

# SEO 每日報告：Search Console 趨勢、關鍵字／頁面漲跌、網站健康檢查。
# 資料由 rake seo:daily（Seo::DailyReportService）每天產生，這裡只讀。
class SeoReportsController < ApplicationController
  CHART_DAYS = 180

  def index
    @report = if params[:date].present?
                SeoReport.find_by(report_date: params[:date])
              else
                SeoReport.order(report_date: :desc).first
              end
    @history = SeoReport.order(report_date: :desc).limit(14).pluck(:report_date, :status)
    @chart = chart_series
  end

  private

  def chart_series
    since = Date.current - CHART_DAYS
    rows = SeoDailyMetric.where("date >= ?", since).order(:date).pluck(:site, :date, :clicks)
    dates = rows.map { |r| r[1] }.uniq.sort
    {
      labels: dates.map { |d| d.strftime("%-m/%-d") },
      series: Seo::Sites::ALL.keys.map do |site|
        by_date = rows.select { |r| r[0] == site }.to_h { |r| [r[1], r[2]] }
        { label: Seo::Sites.label(site), data: dates.map { |d| by_date[d] } }
      end
    }
  end
end
