# frozen_string_literal: true

require "net/http"

# 每日 AI 晨報：讀昨日（最近一個回報日）的 8 部門日誌＋未來 7 天行事曆事件，
# 經 PiiMasker 遮罩後送 Claude API，產出三個區塊落地 daily_briefings：
#   summary           — 全公司昨日摘要（5 行內）
#   dropped_balls     — 跨部門掉球（A 說交給 B，B 未回應）
#   pending_decisions — 部門在等主管回覆的事
# 每項附出處（部門＋日期），首頁可對回行事曆原文查證。
class DailyBriefingService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  MODEL          = "claude-opus-4-8"
  LOOKBACK_DAYS  = 3 # 掉球/待決要看前幾天的上下文，不只昨天

  def self.call(date = Date.current)
    new(date).call
  end

  def initialize(date)
    @date = date
  end

  def call
    briefing = DailyBriefing.find_or_initialize_by(briefing_date: @date)

    report_date = latest_report_date
    if report_date.nil?
      briefing.update!(status: "failed", error_message: "沒有任何部門日誌可供分析")
      return briefing
    end

    api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
    if api_key.blank?
      briefing.update!(status: "failed", error_message: "ANTHROPIC_API_KEY 未設定")
      return briefing
    end

    raw = call_claude(build_prompt(report_date), api_key)
    parsed = parse_response(raw)

    briefing.update!(
      status:            "success",
      summary:           parsed.fetch("summary", []),
      dropped_balls:     parsed.fetch("dropped_balls", []),
      pending_decisions: parsed.fetch("pending_decisions", []),
      error_message:     nil,
      generated_at:      Time.current,
      meta:              { "report_date" => report_date.to_s, "model" => MODEL }
    )
    briefing
  rescue StandardError => e
    Rails.logger.error("[DailyBriefingService] #{e.class}: #{e.message}")
    briefing.update!(status: "failed", error_message: "#{e.class}: #{e.message}")
    briefing
  end

  private

  # 部門不是每天都寫（週末/假日），晨報以「最近一個有回報的日子」為主日
  def latest_report_date
    DepartmentUpdate.where(log_date: ..@date).maximum(:log_date)
  end

  def build_prompt(report_date)
    range = (report_date - LOOKBACK_DAYS + 1)..report_date
    logs = DepartmentUpdate.in_range(range).order(:log_date)
                           .group_by(&:department)
                           .map do |dept, updates|
      body = updates.map { |u| "#{u.log_date}：\n#{PiiMasker.mask(u.content)}" }.join("\n")
      "【#{dept}】\n#{body}"
    end.join("\n\n")

    events = CalendarEvent.where(event_date: @date..(@date + 7))
                          .order(:event_date)
                          .map { |e| "#{e.event_date.strftime('%-m/%-d')} #{e.type_label}：#{e.title}" }
                          .join("\n")

    <<~PROMPT
      你是一家保健食品電商公司的營運幕僚。以下是各部門最近 #{LOOKBACK_DAYS} 天的工作日誌（最新日期 #{report_date}，個資已遮罩）與未來 7 天的公司大事。

      ＝＝ 未來 7 天大事 ＝＝
      #{events.presence || "（無排定事件）"}

      ＝＝ 部門日誌 ＝＝
      #{logs}

      請為老闆和營運主管產出晨報，只輸出 JSON（不要 markdown code fence、不要任何其他文字），格式：
      {
        "summary": [{"text": "…", "source": "部門名 M/D"}],
        "dropped_balls": [{"text": "…", "source": "部門名 M/D"}],
        "pending_decisions": [{"text": "…", "source": "部門名 M/D"}]
      }

      規則：
      - summary：#{report_date.strftime('%-m/%-d')} 全公司發生了什麼，3-5 條，優先挑跟未來 7 天大事相關的動態；每條 40 字以內
      - dropped_balls：跨部門掉球——某部門說已交付/等待另一部門，但對方日誌沒有對應回應；沒有就給空陣列，不要硬湊
      - pending_decisions：部門日誌裡明確在等主管（姐/Serena/公司）回覆或拍板的事項；沒有就給空陣列
      - 每條的 source 標注依據的部門與日期，例如 "設計部 7/12"；跨部門的標兩個，例如 "編輯部 7/11 ↔ 廣告部"
      - 只根據日誌內容，不要推測日誌沒寫的事
    PROMPT
  end

  def call_claude(prompt, api_key)
    uri  = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 180

    req = Net::HTTP::Post.new(uri)
    req["x-api-key"]         = api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = {
      model:      MODEL,
      max_tokens: 4000,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(req)
    body     = JSON.parse(response.body)
    raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"

    body.dig("content", 0, "text").to_s
  end

  def parse_response(text)
    # 模型偶爾仍會包 code fence，剝掉再解析
    json = text[/\{.*\}/m]
    raise "AI 回應不含 JSON：#{text.truncate(200)}" if json.nil?

    parsed = JSON.parse(json)
    %w[summary dropped_balls pending_decisions].index_with do |key|
      Array(parsed[key]).filter_map do |item|
        next unless item.is_a?(Hash) && item["text"].present?

        { "text" => item["text"].to_s, "source" => item["source"].to_s }
      end
    end
  end
end
