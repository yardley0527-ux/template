# frozen_string_literal: true

require "test_helper"

module Seo
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_text(to, text) = @sent << [to, text]
    end

    setup do
      @env = ENV.to_h.slice("LINE_REPORT_CHANNEL_ACCESS_TOKEN", "ANTHROPIC_API_KEY")
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
      ENV.delete("ANTHROPIC_API_KEY") # 不打真的 AI：驗證沒有 AI 時照樣發數字
      LineBotGroup.create!(group_id: "Cboss", active: true)
      LineBotGroup.create!(group_id: "Cold", active: false)
      @report = SeoReport.create!(report_date: Date.new(2026, 10, 20), status: "success", data: {
        "sites" => { "yardley" => {
          "data_through" => "2026-10-17",
          "summary" => { "clicks" => 708 },
          "topics" => { "rising" => [{ "query" => "膝蓋痛吃什麼", "impressions" => 214, "previous_impressions" => 0, "position" => 4.0, "ctr" => 0.02 }],
                        "aio" => [{ "query" => "碳水化合物是什麼", "impressions" => 3707, "position" => 1.0, "ctr" => 0.0005 }] },
          "checks" => [{ "check" => "organization_schema", "label" => "Organization Schema", "url" => "u",
                         "level" => "warning", "detail" => "重複宣告 2 次" },
                       { "check" => "ssl", "label" => "SSL", "url" => "u", "level" => "ok", "detail" => nil }]
        } },
        "articles" => [{ "id" => 1, "title" => "PDRN 全解析", "flags" => ["標題不是問句"], "h2s" => [], "first_paragraph" => "" }]
      })
    end

    teardown do
      %w[LINE_REPORT_CHANNEL_ACCESS_TOKEN ANTHROPIC_API_KEY].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
    end

    test "只發給 active 群組，含數字，不含網站技術問題" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(@report, line: line).call

      to, text = line.sent.first
      assert_equal "Cboss", to
      assert_includes text, "yardley.tw 本週點擊 708"
      refute_includes text, "Organization Schema"
      refute_includes text, "待處理"
      assert_includes text, "膝蓋痛吃什麼：曝光 0→214"
      assert_includes text, "碳水化合物是什麼：排名 1.0、點擊率 0.05%"
      assert_includes text, "〈PDRN 全解析〉\n⚠️ 標題不是問句"
      assert_includes text, LineDigest::REPORT_URL
    end

    test "同一份報告不重複發，FORCE 才重發" do
      line = FakeLine.new
      LineDigest.new(@report, line: line).call
      assert_equal 0, LineDigest.new(@report.reload, line: line).call
      assert_equal 1, LineDigest.new(@report, line: line).call(force: true)
      assert_equal 2, line.sent.size
    end

    test "沒設定 LINE token 就不發" do
      ENV.delete("LINE_REPORT_CHANNEL_ACCESS_TOKEN")
      assert_equal 0, LineDigest.new(@report, line: FakeLine.new).call
    end
  end
end
