# frozen_string_literal: true

module Seo
  # 「Claude SEO 外掛每週報告」推到訂閱「site_health」的 LINE 群組（苼莛國際-總編輯）：
  # 先放搜尋數據（成果、先改哪幾頁、差一點進前幾名的關鍵字、掉最多的頁面），再放全站健檢。
  # 健檢每類問題：頁數、跟上週比、最多 EXAMPLES 個例子；完整清單在 /seo_reports。
  class SiteAuditDigest
    TOPIC = "site_health"
    EXAMPLES = 3
    REPORT_URL = "#{Seo::LineDigest::REPORT_URL}#site-audit"
    WEEKDAYS = %w[日 一 二 三 四 五 六].freeze
    HEADINGS = { "critical" => "❗ 要馬上處理", "warning" => "⚠️ 該修", "info" => "ℹ️ 參考" }.freeze

    def self.call(audit, force: false)
      new(audit).call(force: force)
    end

    def initialize(audit, line: LineBot::Client.new)
      @audit = audit
      @previous = SeoSiteAudit.previous_for(audit)
      @line = line
    end

    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty?

      LineDigestDelivery.deliver_once(TOPIC, @audit.audited_on, force: force) do
        texts = LineBot::Client.pack(sections)
        groups.each { |group| @line.push_texts(group.group_id, texts) }
        groups.size
      end
    end

    def message
      sections.join("\n\n")
    end

    def sections
      counts = @audit.counts
      out = [header(counts)]
      out.concat(insight_sections)
      out << "━━━━━━━━━━━━\n🩺 全站健檢：檢查 #{@audit.pages_checked} 頁#{"（#{@audit.pages_skipped} 頁網站忙碌讀不到）" if @audit.pages_skipped.positive?}\n#{level_summary(counts)}"
      HEADINGS.each do |level, heading|
        types = SiteAudit::TYPES.select { |type, meta| meta[:level] == level && counts[type].to_i.positive? }
        next if types.empty?

        out << ([("━━ #{heading} ━━")] + types.keys.map { |type| type_block(type, counts[type]) }).join("\n\n")
      end
      out << changes_section if @previous
      out << "📋 完整報告（每一頁的網址）：\n#{REPORT_URL}"
      out
    end

    private

    def header(_counts)
      d = @audit.audited_on
      lines = ["📊 Claude SEO 外掛每週報告｜#{d.month}/#{d.day}（#{WEEKDAYS[d.wday]}）", "yardley.tw"]
      range = insights["data_range"]
      lines << "搜尋數據 #{md(range[0])}–#{md(range[1])}（Google 約晚 3 天）" if range
      lines.join("\n")
    end

    def level_summary(counts)
      return "沒有發現問題 ✅" if counts.empty?

      by_level = SiteAudit::TYPES.group_by { |_, m| m[:level] }.transform_values { |v| v.sum { |type, _| counts[type].to_i } }
      "要馬上處理 #{by_level['critical'].to_i}・該修 #{by_level['warning'].to_i}・參考 #{by_level['info'].to_i}"
    end

    def insights
      @audit.insights || {}
    end

    def insight_sections
      out = []
      out << results_section
      if insights["low_ctr"].present?
        out << (["━━ ✏️ 先改這幾頁的標題和描述 ━━", "曝光高、點擊率不到 1%（近 28 天）"] +
                insights["low_ctr"].map { |r| "・#{page_name(r['page'])}\n　曝光 #{num(r['impressions'])}・點擊率 #{pct(r['ctr'])}・排名 #{r['position']}" }).join("\n")
      end
      if insights["striking"].present?
        out << (["━━ 🎯 差一點進前幾名的關鍵字 ━━", "排名 5–15（近 28 天），補強對應的文章"] +
                insights["striking"].map { |r| "・「#{r['query']}」排名 #{r['position']}・曝光 #{num(r['impressions'])}\n　→ #{page_name(r['page'])}" }).join("\n")
      end
      if insights["drops"].present?
        out << (["━━ 📉 點擊掉最多的頁面 ━━", "近 7 天 vs 前 7 天"] +
                insights["drops"].map { |r| "・#{page_name(r['key'])}\n　點擊 #{r['previous_clicks']} → #{r['clicks']}（#{r['change']}）#{rank_change(r)}" }).join("\n")
      end
      out.compact
    end

    def results_section
      lines = ["━━ 💰 自然搜尋成果（近 7 天）━━"]
      if (rev = insights["revenue"])
        lines << "營收 #{money(rev['revenue'])}（前 4 週平均 #{money(rev['base_revenue'])}#{trend(rev['revenue'], rev['base_revenue'])}）"
        lines << "訂單 #{rev['purchases']} 筆・造訪 #{num(rev['sessions'])} 次"
      end
      if (c = insights["clicks"])
        lines << "Google 點擊 #{num(c['week'])}（前 4 週平均 #{num(c['base'])}#{trend(c['week'], c['base'])}）"
      end
      lines.size > 1 ? lines.join("\n") : nil
    end

    def rank_change(r)
      return "" unless r["position"] && r["previous_position"]

      "・排名 #{r['previous_position']} → #{r['position']}"
    end

    def trend(now, base)
      return "" unless base.to_f.positive?

      change = ((now - base) * 100.0 / base).round
      "，#{change.positive? ? '+' : ''}#{change}%"
    end

    def page_name(url)
      key = SiteAudit.page_key(url)
      insights.dig("titles", key).presence || key
    end

    def md(date_str)
      d = Date.parse(date_str)
      "#{d.month}/#{d.day}"
    end

    def num(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    def money(n) = "$#{num(n)}"
    def pct(x) = "#{(x.to_f * 100).round(2)}%"

    def type_block(type, count)
      lines = ["#{SiteAudit::TYPES[type][:label]}：#{count} 頁#{compare(type, count)}"]
      @audit.issues.select { |i| i["type"] == type }.first(EXAMPLES).each do |i|
        name = i["title"].presence || path(i["url"])
        lines << "・#{name}#{"（#{i['detail']}）" if i['detail'].present? && type != 'duplicate_title'}"
      end
      lines << "・…另外 #{count - EXAMPLES} 頁" if count > EXAMPLES
      lines.join("\n")
    end

    def compare(type, count)
      return "" unless @previous

      diff = count - @previous.counts[type].to_i
      diff.zero? ? "（跟上週一樣）" : "（上週 #{@previous.counts[type].to_i}，#{diff.positive? ? '+' : ''}#{diff}）"
    end

    # 這週新出現／修好的頁面（同一類問題比網址）
    def changes_section
      added = 0
      fixed = 0
      SiteAudit::TYPES.each_key do |type|
        now = @audit.issue_urls(type).to_set
        before = @previous.issue_urls(type).to_set
        added += (now - before).size
        fixed += (before - now).size
      end
      "━━ 跟上週（#{@previous.audited_on.month}/#{@previous.audited_on.day}）比 ━━\n新出現 #{added} 項・已修好 #{fixed} 項"
    end

    def path(url)
      CGI.unescape(URI.parse(url.gsub(/[^\x00-\x7F]+/) { |m| CGI.escape(m) }).path.to_s)
    rescue URI::InvalidURIError
      url
    end
  end
end
