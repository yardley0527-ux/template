# frozen_string_literal: true

# 每週全站健檢結果。issues 每筆：{ "type", "url", "title", "detail" }，type 見 Seo::SiteAudit::TYPES。
class SeoSiteAudit < ApplicationRecord
  validates :site, :audited_on, presence: true

  # 「上週」：至少早 6 天的那份（手動補跑的不會被當成上週）
  def self.previous_for(audit)
    where(site: audit.site).where("audited_on <= ?", audit.audited_on - 6).order(audited_on: :desc).first
  end

  def counts
    issues.group_by { |i| i["type"] }.transform_values(&:size)
  end

  def issue_urls(type)
    issues.select { |i| i["type"] == type }.map { |i| i["url"] }
  end
end
