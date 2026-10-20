# frozen_string_literal: true

# 一天一份 SEO 報告（Seo::DailyReportService 產生）。data 結構：
#   "data_through" => GSC 資料最新日期（通常是 3 天前）
#   "sites" => { site => { "summary" => {...}, "movers" => {...}, "checks" => [...] } }
#   "parts" => { "gsc" => { "error" => nil }, "health" => {...}, ... }
class SeoReport < ApplicationRecord
  STATUSES = %w[running success partial failed].freeze

  validates :report_date, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.latest
    where(status: %w[success partial]).order(report_date: :desc).first
  end

  def site_data(site)
    data.dig("sites", site) || {}
  end

  def checks
    (data["sites"] || {}).flat_map { |site, d| (d["checks"] || []).map { |c| c.merge("site" => site) } }
  end
end
