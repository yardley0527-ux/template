# frozen_string_literal: true

require "net/http"

module Seo
  # 每日 SEO 摘要推到「苼莛小幫手」LINE 群組（部門主管）：數字＋目標達成，
  # 再請 Claude 寫 2–3 條重點和一個「今天想一想」，讓主管有東西可以思考，不只看數字。
  # 網站技術問題（Schema、轉址、H1…）是工程師的事，只留在報告頁和營運提醒，不進 LINE。
  # AI 失敗時照樣發，只是少了 AI 那兩段（數字本身不靠 AI）。
  # 同一份報告只發一次（data["line_sent_at"]），手動重跑 seo:daily 不會重複推播。
  class LineDigest
    CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-opus-5-5"
    REPORT_URL = "https://st-crm-v2.onrender.com/seo_reports"

    AI_SCHEMA = {
      type: "object",
      properties: {
        highlights: { type: "array", items: { type: "string" } },
        question: { type: "string" }
      },
      required: %w[highlights question],
      additionalProperties: false
    }.freeze

    def self.call(report, force: false)
      new(report).call(force: force)
    end

    def initialize(report, line: LineBot::Client.new)
      @report = report
      @line = line
    end

    # 回傳發送的群組數；沒設定 LINE、沒有群組、已發過都回 0
    def call(force: false)
      return 0 unless LineBot::Client.configured?
      return 0 if @report.data["line_sent_at"].present? && !force

      groups = LineBotGroup.active.to_a
      return 0 if groups.empty?

      text = message
      groups.each { |group| @line.push_text(group.group_id, text) }
      @report.update!(data: @report.data.merge("line_sent_at" => Time.current.iso8601))
      groups.size
    end

    def message
      ai = ai_commentary
      lines = ["📊 SEO 日報 #{@report.report_date.strftime('%-m/%-d')}（資料到 #{data_through_label}）", ""]
      Sites::ALL.each_key { |site| lines << site_line(site) }

      if ai && ai["highlights"].present?
        lines += ["", "【重點】"]
        ai["highlights"].first(3).each_with_index { |h, i| lines << "#{i + 1}. #{h}" }
      end

      lines += ["", "【💭 今天想一想】", ai["question"]] if ai && ai["question"].present?
      lines += ["", "完整報告 → #{REPORT_URL}"]
      lines.join("\n")
    end

    private

    def site_line(site)
      target = benchmark(site)&.weekly_target
      summary = @report.site_data(site)["summary"]
      return "#{Sites.label(site)}：沒有數據" unless summary

      if target
        mark = target[:clicks_ok] ? "✅" : "❌"
        "#{Sites.label(site)} 本週點擊 #{fmt(target[:clicks])}（目標 #{fmt(target[:target_clicks])} #{mark}）"
      else
        "#{Sites.label(site)} 本週點擊 #{fmt(summary['clicks'])}"
      end
    end

    def benchmark(site)
      through = @report.site_data(site)["data_through"]
      through && Benchmarks.new(site, Date.parse(through))
    end

    def data_through_label
      dates = Sites::ALL.keys.filter_map { |s| @report.site_data(s)["data_through"] }
      dates.any? ? Date.parse(dates.min).strftime("%-m/%-d") : "—"
    end

    def fmt(number)
      ActiveSupport::NumberHelper.number_to_delimited(number)
    end

    # ---- AI ----

    def ai_commentary
      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      return nil if api_key.empty?

      parse(call_claude(prompt, api_key))
    rescue StandardError => e
      Rails.logger.warn("[seo:line_digest] AI 失敗，照樣發數字：#{e.class}: #{e.message}")
      nil
    end

    def prompt
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的 SEO 數據幕僚，要寫一則給部門主管看的 LINE 每日摘要的兩個段落。
        兩個網站：yardley.tw（Shopline 電商，賣保健食品）、shengtingbio.com（WordPress 健康知識雜誌，導流用）。
        SEO 外包合作 2025/10/18–2026/10/17 已結束，現在由公司自己監控。

        以下是今天的數據（JSON，點擊／曝光為每 7 天合計；目標＝前 4 週週平均 × 1.05）：
        #{facts.to_json}

        請產出：
        - highlights：2–3 條今天最值得主管知道的觀察，每條 45 字以內，要有具體數字或關鍵字；
          優先寫「變化大的」和「跟目標或比較基準落差大的」；這是給主管看的成效觀察，不要寫網站技術問題
        - question：一個讓主管思考的問題（60 字以內），要從數據推出一個可以驗證的假設或下一步，
          例如「X 掉了，是因為 A 還是 B？可以看 C 確認」，不要問空泛的問題
        只根據提供的數據，不要編造數據裡沒有的數字或原因；用繁體中文。
      PROMPT
    end

    def facts
      Sites::ALL.each_key.to_h do |site|
        data = @report.site_data(site)
        bench = benchmark(site)
        movers = data["movers"] || {}
        [Sites.label(site), {
          "資料到" => data["data_through"],
          "最近7天" => data["summary"]&.slice("clicks", "impressions", "ctr", "position", "clicks_change_pct"),
          "本週目標" => bench&.weekly_target&.slice(:target_clicks, :clicks_ok, :ctr_target, :ctr_ok, :position_target, :position_ok),
          "比較基準" => bench&.baselines&.map { |b| b.slice(:label, :clicks, :diff_pct) },
          "關鍵字點擊掉最多" => compact_movers(movers.dig("queries", "drops")),
          "關鍵字點擊漲最多" => compact_movers(movers.dig("queries", "gains")),
          "頁面點擊掉最多" => compact_movers(movers.dig("pages", "drops"))
        }]
      end
    end

    def compact_movers(rows)
      Array(rows).first(5).map do |r|
        "#{CGI.unescape(r['key'].to_s)} #{r['previous_clicks']}→#{r['clicks']}（排名 #{r['previous_position'] || '—'}→#{r['position'] || '—'}）"
      end
    end

    # 專案既有慣例（DailyBriefingService）是直接打 Messages API，這裡沿用。
    # fallbacks: "default" — 萬一被安全分類器誤擋，由伺服器自動改用其他模型重跑。
    def call_claude(text, api_key)
      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 180

      req = Net::HTTP::Post.new(uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["anthropic-beta"] = "server-side-fallback-2026-07-01"
      req["content-type"] = "application/json"
      req.body = {
        model: MODEL,
        max_tokens: 16_000,
        fallbacks: "default",
        output_config: { effort: "medium", format: { type: "json_schema", schema: AI_SCHEMA } },
        messages: [{ role: "user", content: text }]
      }.to_json

      response = http.request(req)
      body = JSON.parse(response.body)
      raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"
      raise "Claude 拒絕回應（#{body.dig('stop_details', 'category')}）" if body["stop_reason"] == "refusal"

      Array(body["content"]).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    end

    def parse(text)
      json = JSON.parse(text[/\{.*\}/m].to_s)
      { "highlights" => Array(json["highlights"]).map(&:to_s).reject(&:blank?), "question" => json["question"].to_s }
    end
  end
end
