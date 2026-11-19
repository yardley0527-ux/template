# frozen_string_literal: true

module Seo
  # 每週報告的搜尋數據段落（Search Console＋GA4，不用 AI）：
  #   revenue     — 近 7 天自然搜尋營收／訂單 vs 前 4 週週平均（Benchmarks.ga_week）
  #   clicks      — 近 7 天點擊 vs 前 4 週週平均
  #   low_ctr     — 近 28 天曝光高、點擊率低的頁面：先改標題和描述
  #   striking    — 近 28 天排名 5–15 的關鍵字：差一點進前幾名，補強對應文章
  #   drops       — 近 7 天 vs 前 7 天點擊掉最多的頁面
  class WeeklyInsights
    SITE = "yardley"
    LIMIT = 5
    LOW_CTR_MIN_IMPRESSIONS = 1_000
    LOW_CTR_MAX = 0.01
    LOW_CTR_MAX_POSITION = 20
    STRIKING_POSITIONS = 5.0..15.0
    STRIKING_MIN_IMPRESSIONS = 200

    def initialize(search_console: SearchConsole.new)
      @gsc = search_console
    end

    def call
      end_date = @gsc.latest_date(SITE) or return {}
      month = (end_date - 27)..end_date
      pages = @gsc.rows(SITE, month, ["page"])
      queries = @gsc.rows(SITE, month, %w[query page])

      {
        "data_range" => [(end_date - 6).to_s, end_date.to_s],
        "clicks" => clicks(end_date),
        "revenue" => revenue,
        "low_ctr" => low_ctr(pages),
        "striking" => striking(queries),
        "drops" => @gsc.movers(SITE, end_date: end_date).dig("pages", "drops").to_a.first(LIMIT)
      }
    end

    private

    def clicks(end_date)
      scope = SeoDailyMetric.for_site(SITE)
      week = scope.where(date: (end_date - 6)..end_date).sum(:clicks)
      base = scope.where(date: (end_date - 34)..(end_date - 7)).sum(:clicks) / 4.0
      { "week" => week, "base" => base.round }
    end

    def revenue
      ga = Benchmarks.ga_week(SITE) or return nil
      { "revenue" => ga[:revenue], "purchases" => ga[:purchases], "sessions" => ga[:sessions],
        "base_revenue" => ga[:base_revenue], "end_date" => ga[:end_date].to_s }
    end

    def low_ctr(rows)
      rows.select { |r| r["impressions"] >= LOW_CTR_MIN_IMPRESSIONS && r["ctr"] < LOW_CTR_MAX && r["position"] <= LOW_CTR_MAX_POSITION }
          .sort_by { |r| -r["impressions"] }.first(LIMIT)
          .map { |r| { "page" => r["keys"][0], "impressions" => r["impressions"].to_i, "clicks" => r["clicks"].to_i,
                       "ctr" => r["ctr"].round(4), "position" => r["position"].round(1) } }
    end

    # 同一個關鍵字只留曝光最多的那頁
    def striking(rows)
      rows.select { |r| STRIKING_POSITIONS.cover?(r["position"]) && r["impressions"] >= STRIKING_MIN_IMPRESSIONS }
          .group_by { |r| r["keys"][0] }.values.map { |g| g.max_by { |r| r["impressions"] } }
          .sort_by { |r| -r["impressions"] }.first(LIMIT)
          .map { |r| { "query" => r["keys"][0], "page" => r["keys"][1], "impressions" => r["impressions"].to_i,
                       "clicks" => r["clicks"].to_i, "position" => r["position"].round(1) } }
    end
  end
end
