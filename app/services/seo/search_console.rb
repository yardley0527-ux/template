# frozen_string_literal: true

module Seo
  # Search Console 搜尋成效：
  #   - sync_daily!：每站每日總數 upsert 進 seo_daily_metrics
  #   - movers：最近 7 天 vs 前 7 天，點擊掉最多／漲最多的關鍵字與頁面
  # GSC 資料約有 2–3 天延遲，所以「最近 7 天」是以 latest_date（GSC 最新有資料的那天）往回算。
  class SearchConsole
    API = "https://searchconsole.googleapis.com/webmasters/v3/sites/%s/searchAnalytics/query"
    MOVER_LIMIT = 10
    MIN_PREVIOUS_CLICKS = 5 # 前一週點擊太少的關鍵字漲跌只是雜訊

    def initialize(client: GoogleApiClient.new)
      @client = client
    end

    def sync_daily!(start_date:, end_date:)
      Sites::ALL.keys.index_with do |site|
        rows = query(site, startDate: start_date.to_s, endDate: end_date.to_s, dimensions: ["date"], rowLimit: 25_000)
        now = Time.current
        records = rows.map do |row|
          { site: site, date: row["keys"][0], clicks: row["clicks"].to_i, impressions: row["impressions"].to_i,
            ctr: row["ctr"], position: row["position"], created_at: now, updated_at: now }
        end
        SeoDailyMetric.upsert_all(records, unique_by: %i[site date]) if records.any?
        records.size
      end
    end

    def latest_date(site)
      SeoDailyMetric.for_site(site).where("impressions > 0").maximum(:date)
    end

    # { "queries" => { "drops" => [...], "gains" => [...] }, "pages" => {...} }
    def movers(site, end_date:)
      current  = (end_date - 6)..end_date
      previous = (end_date - 13)..(end_date - 7)
      %w[query page].to_h do |dimension|
        now  = fetch_by(site, dimension, current)
        prev = fetch_by(site, dimension, previous)
        [dimension == "query" ? "queries" : "pages", diff(now, prev)]
      end
    end

    # 選題參考（最近 28 天 vs 前 28 天）：
    #   aio    — 排名前 5 但點擊率 < 1%：答案多半被 Google AI 摘要直接給了，點擊被吃掉
    #   rising — 曝光翻倍的關鍵字：正在變熱門的話題
    AIO_MAX_POSITION = 5
    AIO_MAX_CTR = 0.01
    AIO_MIN_IMPRESSIONS = 300
    RISING_MIN_IMPRESSIONS = 150
    TOPIC_LIMIT = 5

    def topics(site, end_date:)
      current = fetch_by(site, "query", (end_date - 27)..end_date)
      previous = fetch_by(site, "query", (end_date - 55)..(end_date - 28))

      aio = current.values.select do |r|
        r["impressions"] >= AIO_MIN_IMPRESSIONS && r["position"] <= AIO_MAX_POSITION && r["ctr"] < AIO_MAX_CTR
      end
      rising = current.values.filter_map do |r|
        before = previous.dig(r["keys"][0], "impressions").to_i
        next if r["impressions"] < RISING_MIN_IMPRESSIONS || r["impressions"] < before * 2

        r.merge("previous_impressions" => before)
      end

      { "aio" => aio.sort_by { |r| -r["impressions"] }.first(TOPIC_LIMIT).map { |r| topic_row(r) },
        "rising" => rising.sort_by { |r| -(r["impressions"] - r["previous_impressions"]) }.first(TOPIC_LIMIT).map { |r| topic_row(r) } }
    end

    private

    def topic_row(row)
      { "query" => row["keys"][0], "impressions" => row["impressions"].to_i,
        "previous_impressions" => row["previous_impressions"], "position" => row["position"].round(1),
        "ctr" => row["ctr"].round(4) }.compact
    end

    def fetch_by(site, dimension, range)
      query(site, startDate: range.first.to_s, endDate: range.last.to_s, dimensions: [dimension], rowLimit: 1000)
        .to_h { |row| [row["keys"][0], row] }
    end

    def diff(now, prev)
      changes = (now.keys | prev.keys).map do |key|
        cur = now[key] || {}
        old = prev[key] || {}
        { "key" => key,
          "clicks" => cur["clicks"].to_i, "previous_clicks" => old["clicks"].to_i,
          "change" => cur["clicks"].to_i - old["clicks"].to_i,
          "position" => cur["position"]&.round(1), "previous_position" => old["position"]&.round(1) }
      end
      drops = changes.select { |c| c["change"].negative? && c["previous_clicks"] >= MIN_PREVIOUS_CLICKS }
      { "drops" => drops.sort_by { |c| c["change"] }.first(MOVER_LIMIT),
        "gains" => changes.select { |c| c["change"].positive? }.sort_by { |c| -c["change"] }.first(MOVER_LIMIT) }
    end

    def query(site, body)
      property = URI.encode_www_form_component(Sites::ALL.fetch(site)[:gsc_property])
      @client.post_json(format(API, property), body)["rows"] || []
    end
  end
end
