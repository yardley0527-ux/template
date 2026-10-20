# frozen_string_literal: true

module Seo
  # 要監控的兩個網站。gsc_property 要跟 Search Console 資源名稱完全一致
  # （yardley 是網址前置字元資源、shengtingbio 是網域資源）。
  # redirect_hosts：應該 301 到主網域的其他主機名稱，沒轉址＝重複網站。
  module Sites
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
