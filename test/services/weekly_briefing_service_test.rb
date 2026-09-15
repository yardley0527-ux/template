# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingServiceTest < ActiveSupport::TestCase
  class StubbedService < WeeklyBriefingService
    attr_writer :fake_response, :raise_error
    attr_reader :sent_prompt

    private

    def call_claude(prompt, _api_key)
      @sent_prompt = prompt
      raise @raise_error if @raise_error

      @fake_response
    end
  end

  def good_json(one_liner: "測試週摘要", todos: default_todos)
    {
      executive_summary: {
        one_liner: one_liner, status_basis: "b",
        top_findings: [], decisions: [], biggest_risk: nil, biggest_opportunity: nil
      },
      business_analysis: {
        revenue_and_forecast: ["r1"], revenue_change_breakdown: [], new_and_returning_customers: [],
        livestream_performance: [], membership_health: [], product_and_repurchase: [], next_4_week_outlook: []
      },
      action_items: [],
      todos: todos
    }.to_json
  end

  def default_todos
    [{ title: "任務甲", description: "d", priority: "high", suggested_role: "客服", due_date: "2026-06-22",
       data_issue: "di", target_segment: "ts", target_query: {}, expected_kpi: "k" }]
  end

  setup do
    @week_start = Date.new(2026, 6, 15).beginning_of_week(:monday)
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  teardown do
    ENV.delete("ANTHROPIC_API_KEY")
  end

  def build_service(response: good_json, error: nil, week_start: @week_start)
    service = StubbedService.new(week_start)
    service.fake_response = response
    service.raise_error = error
    service
  end

  test "persists a successful briefing with metrics, ai_report, and todos" do
    briefing = build_service.call

    assert_equal "success", briefing.status
    assert_equal @week_start, briefing.week_start
    assert_equal @week_start + 6, briefing.week_end
    assert_equal "測試週摘要", briefing.one_liner
    assert briefing.metrics["revenue_progress"].present?
    assert_equal 1, briefing.todos.count
    assert_equal "任務甲", briefing.todos.first.title
    assert briefing.generated_at.present?
    assert_equal WeeklyBriefingService::MODEL, briefing.model
    assert_equal WeeklyBriefingService::PROMPT_VERSION, briefing.prompt_version
  end

  test "the business status classification comes from WeeklyStatusClassifier, not from the AI response" do
    briefing = build_service.call

    assert_includes WeeklyStatusClassifier::STATUSES, briefing.business_status
    assert_equal briefing.business_status_label, WeeklyStatusClassifier::LABELS[briefing.business_status]
  end

  test "risk flags computed by WeeklyRiskFlagDetector are stored in meta, independent of the AI response" do
    briefing = build_service.call

    assert briefing.meta["risk_flags"].is_a?(Array)
    assert briefing.meta["status_classification"].present?
  end

  test "regenerating the same week updates the existing row instead of creating a duplicate" do
    build_service.call
    assert_no_difference -> { WeeklyBriefing.count } do
      build_service(response: good_json(one_liner: "second", todos: [])).call
    end
    assert_equal "second", WeeklyBriefing.find_by(week_start: @week_start).one_liner
  end

  test "a todo already marked done survives regeneration even if its wording changes, as long as target_query is stable" do
    with_target_query = good_json(todos: [
      { title: "任務甲", description: "d", priority: "high", suggested_role: "客服", due_date: "2026-06-22",
        data_issue: "di", target_segment: "ts",
        target_query: { type: "product_overdue", product_key: "metabolism", min_days: 1, max_days: 30 },
        expected_kpi: "k" }
    ])
    build_service(response: with_target_query).call
    todo = WeeklyBriefing.find_by(week_start: @week_start).todos.first
    todo.mark_done!

    reworded = good_json(one_liner: "second", todos: [
      { title: "任務甲（改了措辭）", description: "d", priority: "high", suggested_role: "客服",
        due_date: "2026-06-22", data_issue: "di", target_segment: "ts",
        target_query: { type: "product_overdue", product_key: "metabolism", min_days: 1, max_days: 30 },
        expected_kpi: "k" }
    ])
    build_service(response: reworded).call

    briefing = WeeklyBriefing.find_by(week_start: @week_start)
    assert_equal 1, briefing.todos.count
    assert briefing.todos.first.done?
    assert_equal "任務甲（改了措辭）", briefing.todos.first.title
  end

  test "a text-only todo (no target_query) is dedupe-matched by title, so a reworded title creates a new row" do
    build_service.call # default_todos' one todo has target_query: {}
    todo = WeeklyBriefing.find_by(week_start: @week_start).todos.first
    todo.mark_done!

    reworded = good_json(one_liner: "second", todos: [
      { title: "任務甲（改了措辭）", description: "d", priority: "high", suggested_role: "客服",
        due_date: "2026-06-22", data_issue: "di", target_segment: "ts", target_query: {}, expected_kpi: "k" }
    ])
    build_service(response: reworded).call

    briefing = WeeklyBriefing.find_by(week_start: @week_start)
    # The old done todo is preserved (pending-only pruning), and a new pending one is added for the new wording.
    assert_equal 2, briefing.todos.count
    assert_equal 1, briefing.todos.done.count
    assert_equal 1, briefing.todos.pending.count
  end

  test "records failed status but still stores metrics when the API errors" do
    briefing = build_service(error: RuntimeError.new("Claude API 529: overloaded")).call

    assert_equal "failed", briefing.status
    assert_includes briefing.error_message, "529"
    assert briefing.metrics["revenue_progress"].present?, "metrics should be saved even when the AI call fails"
  end

  test "records failed status without calling the API when ANTHROPIC_API_KEY is missing" do
    ENV.delete("ANTHROPIC_API_KEY")

    briefing = build_service.call

    assert_equal "failed", briefing.status
    assert_includes briefing.error_message, "ANTHROPIC_API_KEY"
    assert briefing.metrics["revenue_progress"].present?
  end

  test "strips code fences around the JSON response" do
    briefing = build_service(response: "```json\n#{good_json}\n```").call
    assert_equal "success", briefing.status
    assert_equal "測試週摘要", briefing.one_liner
  end

  test "prompt embeds the computed metrics, status classification, and risk flags as JSON, not prose the AI must recompute" do
    service = build_service
    service.call

    assert_includes service.sent_prompt, "revenue_progress"
    assert_includes service.sent_prompt, "本週整體狀態"
    assert_includes service.sent_prompt, "已觸發的風險旗標"
  end
end
