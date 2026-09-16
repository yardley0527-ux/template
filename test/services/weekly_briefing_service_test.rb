# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingServiceTest < ActiveSupport::TestCase
  class StubbedService < WeeklyBriefingService
    attr_writer :raise_error
    attr_reader :sent_prompts, :call_count

    # fake_response 可以是單一字串（每次呼叫都回同一個）或字串陣列（依呼叫
    # 次序輪流回傳，第二次呼叫模擬重試時的回應）。
    def fake_response=(value)
      @fake_responses = value.is_a?(Array) ? value : [value]
    end

    def sent_prompt
      sent_prompts&.last
    end

    private

    def call_claude(prompt, _api_key)
      @sent_prompts ||= []
      @sent_prompts << prompt
      @call_count = (@call_count || 0) + 1
      raise @raise_error if @raise_error

      @fake_responses[[@call_count - 1, @fake_responses.size - 1].min]
    end
  end

  def good_json(one_liner: "測試週摘要", todos: default_todos, decisions: default_decisions)
    {
      executive_summary: {
        one_liner: one_liner, status_basis: "b",
        top_findings: [{ finding: "f1", data_evidence: "d1", why_it_matters: "w1", nature: "short_term", revenue_impact: "r1", confidence: "medium" }],
        decisions: decisions,
        biggest_risk: { description: "risk desc", data_evidence: "evidence" },
        biggest_opportunity: { description: "opp desc", data_evidence: "evidence" }
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

  def default_decisions
    [{ question: "q1", current_situation: "s1", data_evidence: "d1", decision_type: "small_test", confidence: "medium",
       option_a: { action: "a", benefit: "b", risk: "r", condition: "c" },
       option_b: { action: "a2", benefit: "b2", risk: "r2", condition: "c2" }, option_c: nil,
       recommended_option: "A", recommendation_reason: "reason",
       test_design: { target: "逾期30天內的代謝錠顧客", scale: "100人", method: "傳訊息", success_kpi: "回購率10%", stop_condition: "兩週內轉換<2%", decision_point: "兩週後檢視是否擴大" },
       data_needed: nil, impact_if_no_decision: "impact", next_week_kpi: "kpi" }]
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
    assert_equal WeeklyBriefingService::DEFAULT_PROMPT_VERSION, briefing.prompt_version
  end

  test "decision_type and test_design details round-trip through to the stored ai_report" do
    briefing = build_service.call

    decision = briefing.decisions.first
    assert_equal "small_test", decision["decision_type"]
    assert_equal "100人", decision.dig("test_design", "scale")
    assert_equal "medium", briefing.top_findings.first["confidence"]
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

  test "a quality check runs automatically after a successful generation and is readable without querying the database again" do
    briefing = build_service.call

    assert briefing.ai_api_success?
    assert briefing.quality_check.present?
    assert_includes [true, false], briefing.quality_passed?
  end

  test "ai_api_success? is false when the API key is missing, without needing to inspect error_message" do
    ENV.delete("ANTHROPIC_API_KEY")
    briefing = build_service.call

    assert_not briefing.ai_api_success?
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

  test "parses a plain JSON response with no surrounding prose or fences" do
    briefing = build_service(response: good_json).call
    assert_equal "success", briefing.status
  end

  # ── 這一輪修正的核心：AI API HTTP成功、JSON語法合法，但內容是空殼 ──
  test "HTTP success with a syntactically valid but semantically empty executive_summary is not marked success" do
    empty_response = { executive_summary: {}, business_analysis: {} }.to_json

    briefing = build_service(response: empty_response).call

    assert_equal "invalid_response", briefing.status
    assert briefing.ai_api_success?, "the HTTP call itself succeeded, so this should stay true even though the content is invalid"
    assert_not_equal "success", briefing.status
    assert briefing.missing_fields.include?("executive_summary")
    assert_includes briefing.error_message, "AI報告格式異常"
  end

  test "an invalid first response triggers exactly one retry, and a valid retry response is saved as success" do
    empty_response = { executive_summary: {}, business_analysis: {} }.to_json
    service = build_service(response: [empty_response, good_json])

    briefing = service.call

    assert_equal "success", briefing.status
    assert_equal 2, service.call_count
    assert briefing.retried?
    assert_includes service.sent_prompts.last, "重試提示"
    assert_includes service.sent_prompts.last, "executive_summary"
  end

  test "an invalid response that is still invalid after the retry is saved as invalid_response, not success, and only retries once" do
    empty_response = { executive_summary: {}, business_analysis: {} }.to_json
    service = build_service(response: empty_response) # every call returns the same empty response

    briefing = service.call

    assert_equal "invalid_response", briefing.status
    assert_equal 2, service.call_count, "should retry exactly once, not loop forever"
    assert briefing.retried?
    assert briefing.metrics["revenue_progress"].present?, "metrics must still be saved so the page can show real numbers"
  end

  test "a decision missing option_b triggers invalid_response, matching the field-level validator" do
    incomplete_decision = default_decisions.first.merge(option_b: nil)
    response = good_json(decisions: [incomplete_decision])

    briefing = build_service(response: response).call

    assert_equal "invalid_response", briefing.status
    assert_includes briefing.missing_fields, "decisions[0].option_b"
  end

  test "prompt embeds the computed metrics, status classification, and risk flags as JSON, not prose the AI must recompute" do
    service = build_service
    service.call

    assert_includes service.sent_prompt, "revenue_progress"
    assert_includes service.sent_prompt, "本週整體狀態"
    assert_includes service.sent_prompt, "已觸發的風險旗標"
  end

  test "prompt teaches the three-tier evidence system and forbids insufficient-data language in headline fields" do
    service = build_service
    service.call

    assert_includes service.sent_prompt, "三級證據制度"
    assert_includes service.sent_prompt, "A級"
    assert_includes service.sent_prompt, "B級"
    assert_includes service.sent_prompt, "C級"
    assert_includes service.sent_prompt, "禁止出現資料不足"
    assert_includes service.sent_prompt, "decision_type"
    assert_includes service.sent_prompt, "small_test"
  end

  test "prompt tells the AI the data-gap appendix is generated by the program, not by the AI" do
    service = build_service
    service.call

    assert_includes service.sent_prompt, "附錄由程式"
    assert_includes service.sent_prompt, "本週已知的critical等級資料缺口"
  end

  # ── Prompt v5/v6 版本切換 ────────────────────────────────────────
  test "prompt_version defaults to v6 when WEEKLY_BRIEFING_PROMPT_VERSION is unset" do
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
    briefing = build_service.call

    assert_equal "v6", briefing.prompt_version
  end

  test "v6 prompt includes the four business-area signals and headline as read-only AI context" do
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
    service = build_service
    service.call

    assert_includes service.sent_prompt, "四大經營燈號"
    assert_includes service.sent_prompt, "本週週型標題"
    assert_includes service.sent_prompt, "你的敘述不能跟這裡的顏色矛盾"
  end

  test "v6 prompt includes rules 18-20 that v5 does not have" do
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
    service = build_service
    service.call

    assert_includes service.sent_prompt, "revenue_change_breakdown必須明確指出"
  end

  test "setting WEEKLY_BRIEFING_PROMPT_VERSION=v5 rolls back to the frozen v5 prompt (no signals/headline context, no rules 18-20)" do
    ENV["WEEKLY_BRIEFING_PROMPT_VERSION"] = "v5"
    service = build_service
    briefing = service.call

    assert_equal "v5", briefing.prompt_version
    assert_not_includes service.sent_prompt, "四大經營燈號"
    assert_not_includes service.sent_prompt, "本週週型標題"
    assert_not_includes service.sent_prompt, "revenue_change_breakdown必須明確指出"
    # v5 仍然是同一套schema/三級證據制度，不是砍掉重練的舊prompt
    assert_includes service.sent_prompt, "三級證據制度"
  ensure
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
  end

  test "an unsupported WEEKLY_BRIEFING_PROMPT_VERSION value silently falls back to v6, not a typo'd dead branch" do
    ENV["WEEKLY_BRIEFING_PROMPT_VERSION"] = "v99_typo"
    briefing = build_service.call

    assert_equal "v6", briefing.prompt_version
  ensure
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
  end

  # ── 「一、最大風險不能只依賴Prompt（程式保底）」整合測試 ──────────
  # 用 with_stubbed_risk_flags 固定住risk_flags，不依賴本機DB是否剛好
  # 有觸發到high旗標，讓這幾個測試在任何環境下都是deterministic的。
  def mandatory_flags
    [{ key: "new_customer_drop_vs_avg4", category: "new_customer", severity: "high", evidence: {} },
     { key: "product_stockout_risk", category: "product_inventory", severity: "high", evidence: { label: "全能" } }]
  end

  # minitest 6 拿掉了 minitest/mock，這個專案也沒有另外裝 minitest-mock gem，
  # 用 define_singleton_method 暫時換掉class method、跑完再換回來，不需要
  # 額外依賴。
  def with_stubbed_risk_flags(flags)
    original = WeeklyRiskFlagDetector.method(:call)
    WeeklyRiskFlagDetector.define_singleton_method(:call) { |*_args, **_kwargs| flags }
    yield
  ensure
    WeeklyRiskFlagDetector.define_singleton_method(:call, original)
  end

  test "when the AI's first response already covers both mandatory topics, no extra retry call happens and biggest_risk is not overridden" do
    covering = JSON.parse(good_json)
    covering["executive_summary"]["biggest_risk"] = { "description" => "新客人數明顯不足，且全能缺貨", "data_evidence" => "e" }

    service = nil
    with_stubbed_risk_flags(mandatory_flags) do
      service = build_service(response: covering.to_json)
      service.call
    end

    assert_equal 1, service.call_count
    briefing = WeeklyBriefing.find_by(week_start: @week_start)
    assert_equal "新客人數明顯不足，且全能缺貨", briefing.ai_report.dig("executive_summary", "biggest_risk", "description")
    assert_not briefing.meta.dig("quality_check", "mandatory_risk_coverage", "fallback_applied")
  end

  test "when the first response misses both mandatory topics but the retry response covers them, the retried version is used and no override happens" do
    missing = JSON.parse(good_json)
    missing["executive_summary"]["biggest_risk"] = { "description" => "客單價下滑", "data_evidence" => "e" }
    covering = JSON.parse(good_json(one_liner: "second"))
    covering["executive_summary"]["biggest_risk"] = { "description" => "新客不足與全能缺貨同時發生", "data_evidence" => "e" }

    service = nil
    with_stubbed_risk_flags(mandatory_flags) do
      service = build_service(response: [missing.to_json, covering.to_json])
      service.call
    end

    assert_equal 2, service.call_count
    assert_includes service.sent_prompts.last, "重試提示（風險涵蓋）"
    briefing = WeeklyBriefing.find_by(week_start: @week_start)
    assert_equal "second", briefing.one_liner
    assert_equal "新客不足與全能缺貨同時發生", briefing.ai_report.dig("executive_summary", "biggest_risk", "description")
    assert_not briefing.meta.dig("quality_check", "mandatory_risk_coverage", "fallback_applied")
  end

  test "when neither the first response nor the retry covers the mandatory topics, biggest_risk is programmatically overridden and quality_check records the reason" do
    missing = JSON.parse(good_json)
    missing["executive_summary"]["biggest_risk"] = { "description" => "客單價下滑", "data_evidence" => "e" }

    service = nil
    with_stubbed_risk_flags(mandatory_flags) do
      service = build_service(response: missing.to_json) # every call returns the same non-covering response
      service.call
    end

    assert_equal 2, service.call_count
    briefing = WeeklyBriefing.find_by(week_start: @week_start)
    override = briefing.ai_report.dig("executive_summary", "biggest_risk")
    assert override["program_generated"]
    assert_includes override["description"], "同時發生"
    assert briefing.meta.dig("quality_check", "mandatory_risk_coverage", "fallback_applied")
    assert briefing.meta.dig("quality_check", "failed_items").any? { |f| f.include?("最大風險保底") }
    assert_not briefing.quality_passed?
  end

  test "when there are no high-severity flags, mandatory_topics is empty and no retry or override ever fires" do
    service = nil
    with_stubbed_risk_flags([]) do
      service = build_service
      service.call
    end

    assert_equal 1, service.call_count
  end

  # ── View不依賴AI自行產生燈號：業務燈號只能來自程式算的 business_signals ──
  test "business_signals stored in meta come from WeeklyBusinessSignalClassifier regardless of what the AI returns, and AI JSON has no signal-color field" do
    ENV.delete("WEEKLY_BRIEFING_PROMPT_VERSION")
    briefing = build_service.call

    signals = briefing.meta["business_signals"]["signals"]
    assert_equal 4, signals.size
    assert_equal %w[revenue new_customer old_customer product_inventory], signals.map { |s| s["area"] }
    assert(signals.all? { |s| %w[green yellow red gray].include?(s["status"]) })
    # ai_report（存起來的AI輸出）本身沒有business_signals或status顏色欄位可讀，
    # 證明畫面只能從程式算的meta讀燈號，不是從AI JSON讀
    assert_not briefing.ai_report.key?("business_signals")
  end
end
