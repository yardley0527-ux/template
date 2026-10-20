# frozen_string_literal: true

module Seo
  # 每天產生一份 SeoReport：
  #   1. Search Console 每日總數重抓最近 10 天（GSC 會回頭修正）
  #   2. 每站最近 7 天 vs 前 7 天摘要 + 關鍵字／頁面漲跌
  #   3. 網站健康檢查
  #   4. 選題參考（疑似被 AI 摘要吃掉點擊、正在變熱門的關鍵字）＋昨日文章健檢
  # 各段獨立 rescue：GSC 掛了健康檢查照跑，反之亦然（狀態記成 partial）。
  # 留 SyncRun(source: "seo_daily") 紀錄，失敗會被既有 system_health 規則抓到。
  class DailyReportService
    RESYNC_DAYS = 10
    # 歷史不足一年（例如新環境第一次跑）就一次回補 GSC 能給的 16 個月，
    # 不用另外在正式站手動跑 seo:backfill
    HISTORY_DAYS = 480
    MIN_HISTORY_DAYS = 365

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(date: Date.current, search_console: nil, health_check: nil, article_review: nil)
      @date = date
      @search_console = search_console
      @health_check = health_check
      @article_review = article_review
    end

    def call
      run = SyncRun.create!(source: "seo_daily", started_at: Time.current)
      report = SeoReport.find_or_initialize_by(report_date: @date)
      report.update!(status: "running", error_message: nil)

      parts = {}
      sites = Sites::ALL.keys.index_with { {} }

      parts["gsc"] = capture do
        search_console.sync_daily!(start_date: sync_start_date, end_date: @date)
        Sites::ALL.each_key do |site|
          latest = search_console.latest_date(site)
          next unless latest

          sites[site]["data_through"] = latest.to_s
          sites[site]["summary"] = summary(site, latest)
          sites[site]["movers"] = search_console.movers(site, end_date: latest)
          sites[site]["topics"] = search_console.topics(site, end_date: latest)
        end
      end

      parts["health"] = capture do
        Sites::ALL.each_key { |site| sites[site]["checks"] = health_check.call(site) }
      end

      articles = []
      parts["articles"] = capture { articles = article_review.call }

      errors = parts.values.filter_map { |p| p["error"] }
      status = if errors.empty? then "success" elsif errors.size == parts.size then "failed" else "partial" end
      report.update!(status: status, data: { "sites" => sites, "articles" => articles, "parts" => parts }, error_message: errors.join("；").presence)
      run.update!(status: status, finished_at: Time.current, meta: parts, error_messages: errors)
      report
    rescue StandardError => e
      run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
      report&.update!(status: "failed", error_message: "#{e.class}: #{e.message}")
      raise
    end

    # 最近 7 天 vs 前 7 天。平均排名用曝光加權（GSC 介面也是這樣算）。
    def summary(site, end_date)
      current  = window(site, (end_date - 6)..end_date)
      previous = window(site, (end_date - 13)..(end_date - 7))
      current.merge("previous" => previous,
                    "clicks_change_pct" => pct_change(current["clicks"], previous["clicks"]),
                    "impressions_change_pct" => pct_change(current["impressions"], previous["impressions"]))
    end

    private

    def sync_start_date
      oldest = SeoDailyMetric.minimum(:date)
      return @date - HISTORY_DAYS if oldest.nil? || oldest > @date - MIN_HISTORY_DAYS

      @date - RESYNC_DAYS
    end

    def window(site, range)
      rows = SeoDailyMetric.for_site(site).where(date: range)
      clicks = rows.sum(:clicks)
      impressions = rows.sum(:impressions)
      weighted = rows.sum("position * impressions").to_f
      { "clicks" => clicks, "impressions" => impressions,
        "ctr" => impressions.positive? ? (clicks.to_f / impressions).round(4) : nil,
        "position" => impressions.positive? ? (weighted / impressions).round(1) : nil }
    end

    def pct_change(now, before)
      return nil unless before.to_i.positive?

      ((now - before) * 100.0 / before).round(1)
    end

    def capture
      yield
      { "error" => nil }
    rescue StandardError => e
      Rails.logger.error("[seo] #{e.class}: #{e.message}")
      { "error" => "#{e.class}: #{e.message}" }
    end

    def search_console
      @search_console ||= SearchConsole.new
    end

    def health_check
      @health_check ||= HealthCheck.new(date: @date)
    end

    def article_review
      @article_review ||= ArticleReview.new(date: @date)
    end
  end
end
