# frozen_string_literal: true

# Search Console 每站每日總數（點擊／曝光／點擊率／平均排名），由
# Seo::SearchConsoleSync 寫入。GSC 會回頭修正最近幾天的數字，所以每天重抓
# 最近 10 天覆蓋。
class SeoDailyMetric < ApplicationRecord
  validates :site, inclusion: { in: Seo::Sites::ALL.keys }
  validates :date, presence: true

  scope :for_site, ->(site) { where(site: site) }
end
