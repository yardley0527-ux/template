# frozen_string_literal: true

require "net/http"

module IgInbox
  # 跟 OrderBrief::Highlights 同一套：直接打 Messages API（專案慣例），回傳解析好的 JSON。
  module Claude
    API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-opus-5-5"

    module_function

    def call(text, schema)
      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      raise "ANTHROPIC_API_KEY 未設定" if api_key.empty?

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 300

      req = Net::HTTP::Post.new(uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["anthropic-beta"] = "server-side-fallback-2026-07-01"
      req["content-type"] = "application/json"
      req.body = {
        model: MODEL,
        max_tokens: 32_000,
        fallbacks: "default",
        output_config: { effort: "medium", format: { type: "json_schema", schema: schema } },
        messages: [{ role: "user", content: text }]
      }.to_json

      response = http.request(req)
      body = JSON.parse(response.body)
      raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"
      raise "Claude 拒絕回應（#{body.dig('stop_details', 'category')}）" if body["stop_reason"] == "refusal"
      raise "Claude 輸出被截斷（max_tokens）" if body["stop_reason"] == "max_tokens"

      text = Array(body["content"]).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
      JSON.parse(text[/\{.*\}/m].to_s)
    end
  end
end
