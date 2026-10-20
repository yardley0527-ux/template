# frozen_string_literal: true

module Seo
  # GA4：SEO 帶來的生意。兩站在同一個資源（438779977），用 hostName 拆開。
  #   sync_daily!     — 每站每日「自然搜尋」工作階段／訂單／營收，以及雜誌導到官網的流量，
  #                     寫進 seo_daily_metrics 的 ga_* / referred_* 欄位
  #   revenue_pages   — 自然搜尋進站、帶來最多營收的 yardley 頁面
  # GA4 約有 1 天延遲，資料到昨天。
  class Analytics
    API = "https://analyticsdata.googleapis.com/v1beta/properties/%s:runReport"
    ORGANIC = "Organic Search"
    PAGE_LIMIT = 5
    # 購物車／結帳／訂單確認頁當進站頁＝客人回來結帳時重開的工作階段，不是 SEO 帶進來的頁面
    NON_LANDING_PAGES = %w[/cart /checkout /orders].freeze

    def initialize(client: GoogleApiClient.new)
      @client = client
    end

    def sync_daily!(start_date:, end_date:)
      dates = { startDate: start_date.to_s, endDate: end_date.to_s }
      Sites::ALL.to_h do |site, config|
        organic = report(dateRanges: [dates], dimensions: [{ name: "date" }], metrics: metrics,
                         dimensionFilter: and_filter(host_filter(config[:ga_hosts]), channel_filter))
        upsert(site, organic, ga_sessions: :sessions, ga_purchases: :purchases, ga_revenue: :revenue)

        if config[:referral_source]
          source = { filter: { fieldName: "sessionSource",
                               stringFilter: { matchType: "CONTAINS", value: config[:referral_source] } } }
          referred = report(dateRanges: [dates], dimensions: [{ name: "date" }], metrics: metrics,
                            dimensionFilter: and_filter(host_filter(Sites::SHOP_HOSTS), source))
          upsert(site, referred, referred_sessions: :sessions, referred_purchases: :purchases, referred_revenue: :revenue)
        end
        [site, organic.size]
      end
    end

    def latest_date(site)
      SeoDailyMetric.for_site(site).where.not(ga_sessions: nil).maximum(:date)
    end

    def revenue_pages(site, end_date:)
      rows = raw_report(dateRanges: [{ startDate: (end_date - 27).to_s, endDate: end_date.to_s }],
                        dimensions: [{ name: "landingPage" }], metrics: metrics,
                        dimensionFilter: and_filter(host_filter(Sites::ALL.fetch(site)[:ga_hosts]), channel_filter),
                        orderBys: [{ metric: { metricName: "purchaseRevenue" }, desc: true }], limit: PAGE_LIMIT * 3)
      rows.filter_map do |row|
        values = row["metricValues"].map { |v| v["value"] }
        next if values[2].to_f.zero? || NON_LANDING_PAGES.any? { |p| row["dimensionValues"][0]["value"].start_with?(p) }

        { "page" => row["dimensionValues"][0]["value"], "sessions" => values[0].to_i,
          "purchases" => values[1].to_i, "revenue" => values[2].to_f.round }
      end.first(PAGE_LIMIT)
    end

    private

    def metrics
      [{ name: "sessions" }, { name: "ecommercePurchases" }, { name: "purchaseRevenue" }]
    end

    def host_filter(hosts)
      { filter: { fieldName: "hostName", inListFilter: { values: hosts } } }
    end

    def channel_filter
      { filter: { fieldName: "sessionDefaultChannelGroup", stringFilter: { value: ORGANIC } } }
    end

    def and_filter(*expressions)
      { andGroup: { expressions: expressions } }
    end

    def report(body)
      raw_report(body.merge(limit: 1000)).map do |row|
        values = row["metricValues"].map { |v| v["value"] }
        { date: Date.strptime(row["dimensionValues"][0]["value"], "%Y%m%d"),
          sessions: values[0].to_i, purchases: values[1].to_i, revenue: values[2].to_f.round(2) }
      end
    end

    def raw_report(body)
      @client.post_json(format(API, Sites::GA4_PROPERTY), body)["rows"] || []
    end

    # 只更新指定欄位，不動同一列的 Search Console 欄位
    def upsert(site, rows, mapping)
      return if rows.empty?

      now = Time.current
      records = rows.map do |row|
        mapping.transform_values { |key| row[key] }.merge(site: site, date: row[:date], created_at: now, updated_at: now)
      end
      SeoDailyMetric.upsert_all(records, unique_by: %i[site date], update_only: mapping.keys)
    end
  end
end
