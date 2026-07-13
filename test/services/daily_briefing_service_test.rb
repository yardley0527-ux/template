# frozen_string_literal: true

require "test_helper"

class DailyBriefingServiceTest < ActiveSupport::TestCase
  # 攔掉真正的 API 呼叫
  class StubbedService < DailyBriefingService
    attr_writer :fake_response, :raise_error
    attr_reader :sent_prompt

    private

    def call_claude(prompt, _api_key)
      @sent_prompt = prompt
      raise @raise_error if @raise_error

      @fake_response
    end
  end

  GOOD_JSON = {
    summary: [{ text: "設計部完成美白圖卡三張", source: "設計部 7/13" }],
    dropped_balls: [{ text: "編輯部文字已交廣告部，廣告部未確認", source: "編輯部 7/12 ↔ 廣告部" }],
    pending_decisions: []
  }.to_json

  setup do
    travel_to Time.zone.local(2026, 7, 13, 7, 30, 0)
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    DepartmentUpdate.create!(department: "設計部", log_date: Date.new(2026, 7, 13),
                             content: "美白圖卡 x3 已交檔\n黑卡會員 林庭羽 生日禮物 0988103909")
    CalendarEvent.create!(title: "品牌之夜：美白", event_type: "livestream",
                          event_date: Date.new(2026, 7, 17))
  end

  teardown do
    travel_back
    ENV.delete("ANTHROPIC_API_KEY")
  end

  def build_service(response: GOOD_JSON, error: nil)
    service = StubbedService.new(Date.current)
    service.fake_response = response
    service.raise_error = error
    service
  end

  test "persists a successful briefing with all three sections" do
    briefing = build_service.call

    assert_equal "success", briefing.status
    assert_equal 1, briefing.summary.size
    assert_equal "設計部完成美白圖卡三張", briefing.summary.first["text"]
    assert_equal "設計部 7/13", briefing.summary.first["source"]
    assert_equal 1, briefing.dropped_balls.size
    assert_empty briefing.pending_decisions
    assert_equal "2026-07-13", briefing.meta["report_date"]
    assert briefing.generated_at.present?
  end

  test "prompt masks PII and includes calendar events" do
    service = build_service
    service.call

    assert_includes service.sent_prompt, "[客人]"
    assert_includes service.sent_prompt, "[電話]"
    assert_not_includes service.sent_prompt, "林庭羽"
    assert_not_includes service.sent_prompt, "0988103909"
    assert_includes service.sent_prompt, "品牌之夜：美白"
  end

  test "strips code fences around the JSON" do
    briefing = build_service(response: "```json\n#{GOOD_JSON}\n```").call

    assert_equal "success", briefing.status
    assert_equal 1, briefing.summary.size
  end

  test "records failed status when the API errors, homepage still renders" do
    briefing = build_service(error: RuntimeError.new("Claude API 529: overloaded")).call

    assert_equal "failed", briefing.status
    assert_includes briefing.error_message, "529"
  end

  test "fails cleanly when no department logs exist" do
    DepartmentUpdate.delete_all

    briefing = build_service.call
    assert_equal "failed", briefing.status
    assert_includes briefing.error_message, "沒有任何部門日誌"
  end

  test "rerunning the same date overwrites instead of duplicating" do
    build_service.call
    assert_no_difference -> { DailyBriefing.count } do
      build_service(response: { summary: [], dropped_balls: [], pending_decisions: [] }.to_json).call
    end
    assert_empty DailyBriefing.latest.summary
  end

  test "uses the latest report date when today has no logs" do
    DepartmentUpdate.delete_all
    DepartmentUpdate.create!(department: "物流部", log_date: Date.new(2026, 7, 11), content: "出貨")

    service = build_service
    briefing = service.call

    assert_equal "success", briefing.status
    assert_equal "2026-07-11", briefing.meta["report_date"]
  end
end
