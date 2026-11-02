# frozen_string_literal: true

require "test_helper"

class Manychat::QuestionDigestTest < ActiveSupport::TestCase
  def ask(text, at)
    @row = (@row || 1) + 1
    IgQuestion.create!(account_key: "chloe.chao", sheet_row: @row, question: text, asked_at: Time.zone.parse(at))
  end

  test "AI 分類寫回每則訊息，總結和建議存成當天整理；做過就不重做" do
    q1 = ask("全能多少錢", "2026-11-01 09:00")
    q2 = ask("懷孕可以吃嗎", "2026-11-01 23:30")
    ask("隔天的問題", "2026-11-02 00:10")

    reply = { questions: [{ id: q1.id, category: "價格／優惠活動", sensitive: false, sensitive_reason: "" },
                          { id: q2.id, category: "產品功效／適合誰", sensitive: true, sensitive_reason: "懷孕" }],
              overview: "共 2 則。", suggestions: [{ title: "全能價格", detail: "1 則在問" }] }.to_json
    calls = 0
    service = Manychat::QuestionDigest.new(Date.new(2026, 11, 1))
    service.define_singleton_method(:call_claude) do |text, _key|
      calls += 1
      raise "送了隔天的問題" if text.include?("隔天的問題")
      reply
    end

    ENV["ANTHROPIC_API_KEY"] = "test"
    digest = service.call
    assert_equal ["done", "共 2 則。", 1], [digest.status, digest.overview, digest.suggestions.size]
    assert_equal ["價格／優惠活動", false], [q1.reload.category, q1.sensitive]
    assert_equal [true, "懷孕"], [q2.reload.sensitive, q2.sensitive_reason]

    service.call
    assert_equal 1, calls
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "沒有問題的日子不打 AI，直接記成沒有" do
    digest = Manychat::QuestionDigest.call(Date.new(2026, 10, 1))
    assert_equal ["done", []], [digest.status, digest.suggestions]
  end
end
