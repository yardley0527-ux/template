# frozen_string_literal: true

module NotificationRules
  # seo_health — 讀最新一份 SeoReport（Seo::DailyReportService 產生），推兩種警訊：
  #   1. 健康檢查 critical/warning（noindex、首頁打不開、description 爆量、www 重複網站…）
  #      info/ok 只留在報告頁，不推板子（例如圖片 alt 覆蓋率是長期待辦，不是每天的事件）
  #   2. 自然搜尋點擊最近 7 天比前 7 天掉超過 30%
  # 報告太舊（>2 天）就不推，免得拿過期結果一直開卡；報告沒產生由 system_health
  # 的 SyncRun 規則負責。
  class SeoHealth
    MAX_REPORT_AGE = 2.days
    CLICK_DROP_PCT = -30.0
    MIN_PREVIOUS_CLICKS = 100 # 前一週點擊太少，百分比波動沒有意義

    LEVEL_TO_SEVERITY = { "critical" => ["critical", "P0"], "warning" => ["warning", "P2"] }.freeze

    ACTIONS = {
      "noindex"             => "到網站後台（Shopline SEO 設定／WordPress AIOSEO）確認這頁的「不要索引」有沒有被勾起來。",
      "page_status"         => "打開網址確認網站是否正常；首頁打不開要立刻聯絡 Shopline／主機。",
      "robots"              => "檢查 robots.txt 是否被改成 Disallow: /，這會讓 Google 停止爬整個網站。",
      "meta_description"    => "到後台把這頁的 SEO 描述改成 160 字以內；yardley 商品頁要在 Shopline 商品的「SEO 設定」填寫描述，沒填會直接截取商品內文。",
      "canonical"           => "確認頁面的 canonical 網址設定正確。",
      "organization_schema" => "找出主題裡重複輸出的 Organization Schema，只保留含統編與聯絡資訊的完整版。",
      "h1"                  => "確認首頁有一個 H1 標題。",
      "sitemap"             => "確認 sitemap.xml 能正常打開，並重新提交到 Search Console。",
      "redirect"            => "在 DNS／Cloudflare 設定轉址，讓其他主機名稱 301 到主網域；SSL 錯誤要在網域商或 Shopline 補上憑證。",
      "ssl"                 => "SSL 憑證快到期，確認 Cloudflare／主機的自動續期是否正常。"
    }.freeze

    def self.call
      new.call
    end

    def call
      report = SeoReport.latest
      return [] if report.nil? || report.report_date < Date.current - MAX_REPORT_AGE

      check_alerts(report) + traffic_alerts(report)
    end

    private

    def check_alerts(report)
      grouped = report.checks.select { |c| LEVEL_TO_SEVERITY.key?(c["level"]) }.group_by { |c| [c["site"], c["check"]] }
      grouped.map do |(site, check), items|
        worst = items.min_by { |c| Seo::HealthCheck::LEVELS.index(c["level"]) }
        severity, priority = LEVEL_TO_SEVERITY.fetch(worst["level"])
        label = Seo::Sites.label(site)
        build(key: "seo_health_check", severity: severity, priority: priority,
              title: "#{label}：#{worst['label']} 異常",
              message: items.map { |c| "#{c['detail']}（#{c['url']}）" }.uniq.first(3).join("；"),
              impact_summary: worst["level"] == "critical" ? "可能讓網站從 Google 搜尋結果消失。" : "會降低搜尋排名或點擊率。",
              recommended_action: ACTIONS[check],
              subject_id: "#{site}:#{check}",
              metadata: { site: site, check: check, report_date: report.report_date.to_s, urls: items.map { |c| c["url"] }.uniq })
      end
    end

    def traffic_alerts(report)
      Seo::Sites::ALL.keys.filter_map do |site|
        summary = report.site_data(site)["summary"]
        next unless summary

        change = summary["clicks_change_pct"]
        previous = summary.dig("previous", "clicks").to_i
        next if change.nil? || change > CLICK_DROP_PCT || previous < MIN_PREVIOUS_CLICKS

        label = Seo::Sites.label(site)
        build(key: "seo_traffic_drop", severity: "warning", priority: "P1",
              title: "#{label} 自然搜尋點擊下滑 #{change.abs}%",
              message: "最近 7 天 #{summary['clicks']} 次，前 7 天 #{previous} 次（資料到 #{report.site_data(site)['data_through']}）",
              impact_summary: "自然搜尋帶來的流量明顯減少。",
              recommended_action: "到 SEO 報告看掉最多的關鍵字和頁面，確認是否排名下滑、頁面出問題，或只是節慶／檔期波動。",
              subject_id: site,
              metadata: { site: site, clicks: summary["clicks"], previous_clicks: previous, change_pct: change })
      end
    end

    def build(key:, severity:, priority:, title:, message:, impact_summary:, recommended_action:, subject_id:, metadata:)
      {
        notification_key: key, kind: "alert", severity: severity, priority: priority, title: title, message: message,
        impact_summary: impact_summary, recommended_action: recommended_action,
        subject_type: "seo_site", subject_id: subject_id, metadata: metadata,
        deduplication_key: "#{key}:seo_site:#{subject_id}"
      }
    end
  end
end
