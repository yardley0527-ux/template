# frozen_string_literal: true

module Seo
  # 要監控的兩個網站。gsc_property 要跟 Search Console 資源名稱完全一致
  # （yardley 是網址前置字元資源、shengtingbio 是網域資源）。
  # redirect_hosts：應該 301 到主網域的其他主機名稱，沒轉址＝重複網站。
  module Sites
    # 積木（stack）SEO 合作期間，當成比較基準之一
    CONTRACT_PERIOD = Date.new(2025, 10, 18)..Date.new(2026, 10, 17)

    # 浮動目標：本週點擊 ≥ 前 4 週週平均 × (1 + TARGET_GROWTH)；點擊率、排名不能比前 4 週差。
    # 只看上一週波動太大（連假、直播檔期），所以用前 4 週平均當標準。
    TARGET_GROWTH = 0.05
    TARGET_BASE_DAYS = 28

    ALL = {
      "yardley" => {
        label: "yardley.tw",
        gsc_property: "https://www.yardley.tw/",
        base_url: "https://www.yardley.tw",
        redirect_hosts: %w[yardley.tw]
      },
      "shengtingbio" => {
        label: "shengtingbio.com",
        gsc_property: "sc-domain:shengtingbio.com",
        base_url: "https://shengtingbio.com",
        redirect_hosts: %w[www.shengtingbio.com]
      }
    }.freeze

    def self.label(site)
      ALL.dig(site, :label) || site
    end
  end
end
