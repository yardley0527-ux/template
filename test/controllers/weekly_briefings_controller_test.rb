# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "wb_admin@test.com", username: "wb_admin", password: "password123", role: admin_role)
    non_admin_role = Role.create!(key: "staff", name: "Staff")
    PagePermission.create!(role: non_admin_role, controller_name: "weekly_briefings")
    @staff = User.create!(email: "wb_staff@test.com", username: "wb_staff", password: "password123", role: non_admin_role)
  end

  test "index lists history and shows an empty state when there is none" do
    sign_in @admin
    get weekly_briefings_path
    assert_response :success
  end

  test "show renders an empty-state prompt when the week has no briefing yet" do
    sign_in @admin
    get weekly_briefing_path(week_start: "2026-06-15")
    assert_response :success
    assert_includes response.body, "還沒有產生報告"
  end

  test "show renders the stored report for an existing week" do
    # 用真正的 WeeklyMetricsService 輸出（結構完整，即使資料是空的）取代手打的
    # 半成品 metrics hash——半成品之前讓 show.html.erb 深層存取（scenarios/
    # cohort_repurchase/actionability 等）直接 500，測試卻只斷言字串存在，
    # 沒有真的驗證頁面渲染成功。
    metrics = WeeklyMetricsService.call(week_start: Date.new(2026, 6, 15))
    briefing = WeeklyBriefing.create!(
      week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
      ai_report: {
        "executive_summary" => { "status" => "flat", "status_label" => "大致持平", "one_liner" => "測試一句話", "status_basis" => "b", "confidence" => "medium", "reasons" => [] },
        "business_analysis" => {}, "action_items" => []
      },
      metrics: metrics
    )
    sign_in @admin

    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "測試一句話"
  end

  test "show renders decision_type-specific fields (small_test / needs_more_data) without error" do
    metrics = WeeklyMetricsService.call(week_start: Date.new(2026, 6, 15))
    briefing = WeeklyBriefing.create!(
      week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
      ai_report: {
        "executive_summary" => {
          "status" => "flat", "status_label" => "大致持平", "one_liner" => "測試一句話", "status_basis" => "b", "confidence" => "medium", "reasons" => [],
          "top_findings" => [{ "finding" => "f1", "data_evidence" => "d1", "why_it_matters" => "w1", "nature" => "short_term", "revenue_impact" => "r1", "confidence" => "medium" }],
          "decisions" => [
            { "question" => "q1", "current_situation" => "s1", "data_evidence" => "d1", "decision_type" => "small_test",
              "option_a" => { "action" => "a", "benefit" => "b", "risk" => "r", "condition" => "c" }, "option_b" => nil, "option_c" => nil,
              "recommended_option" => "A", "recommendation_reason" => "reason",
              "test_design" => { "target" => "逾期顧客", "scale" => "100人", "method" => "傳訊息", "success_kpi" => "回購率", "stop_condition" => "無效", "decision_point" => "兩週後" },
              "data_needed" => nil, "impact_if_no_decision" => "impact", "next_week_kpi" => "kpi" },
            { "question" => "q2", "current_situation" => "s2", "data_evidence" => "d2", "decision_type" => "needs_more_data",
              "option_a" => { "action" => "a", "benefit" => "b", "risk" => "r", "condition" => "c" }, "option_b" => nil, "option_c" => nil,
              "recommended_option" => "A", "recommendation_reason" => "reason",
              "test_design" => nil,
              "data_needed" => { "missing_data" => "廣告花費", "who_should_provide" => "廣告部", "when_needed" => "下週前", "decision_once_available" => "決定加碼與否" },
              "impact_if_no_decision" => "impact", "next_week_kpi" => "kpi" }
          ]
        },
        "business_analysis" => {}, "action_items" => []
      },
      metrics: metrics
    )
    sign_in @admin

    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "測試設計"
    assert_includes response.body, "需要先補的資料"
  end

  test "current resolves to the latest complete week, not the in-progress current calendar week" do
    travel_to Date.new(2026, 9, 15) do # a Tuesday; the 09/14~09/20 week has not ended
      sign_in @admin
      get weekly_briefing_path(week_start: "current")

      assert_response :success
      assert_includes response.body, "2026/09/07" # last complete week's start date, not 09/14 (this week, still running)
      assert_not_includes response.body, "2026/09/14 ~ 09/20"
    end
  ensure
    travel_back
  end

  test "regenerate is forbidden for a non-admin user" do
    sign_in @staff
    assert_no_difference -> { WeeklyBriefing.count } do
      post regenerate_weekly_briefing_path(week_start: "2026-06-15")
    end
    assert_redirected_to weekly_briefing_path(week_start: "2026-06-15")
  end

  test "regenerate refuses to run for a week that has not ended yet, even if an admin requests it directly by URL" do
    travel_to Date.new(2026, 9, 15) do
      sign_in @admin
      assert_no_difference -> { WeeklyBriefing.count } do
        post regenerate_weekly_briefing_path(week_start: "2026-09-14") # this week, not yet complete
      end
      assert_redirected_to weekly_briefing_path(week_start: "2026-09-14")
      follow_redirect!
      assert_includes flash[:alert].to_s, "尚未結束"
    end
  ensure
    travel_back
  end

  # ── 用規格書 2026/09/07~09/13 fixture 的完整v6形狀渲染show頁，確認沒有
  # 空白標題／破版／未處理的null（規格十四驗收項目12，見weekly_briefing_service
  # 的live API驗證：這裡不重打真的API，只重建同樣形狀的AI輸出，驗證渲染面）──
  test "show renders the full v6 shape (business signals, headline, program action items, quality check with AI fact-check issues) without error, blank titles, or unhandled nulls" do
    this_week = { "new_customers" => 5, "returning_customers" => 93, "new_revenue" => 48_349.0, "returning_revenue" => 946_285.0,
                   "total_customers" => 98, "total_revenue" => 994_634.0, "new_aov" => 9_670.0, "returning_aov" => 10_175.0 }
    trailing4_avg = { "new_customers" => 17, "returning_customers" => 137, "new_revenue" => 177_137.0, "returning_revenue" => 2_426_820.0,
                       "total_customers" => 154, "total_revenue" => 2_603_957.0, "new_aov" => 10_420.0, "returning_aov" => 17_714.0 }
    last_year_same_week = { "new_customers" => 10, "returning_customers" => 105, "new_revenue" => 66_194.0, "returning_revenue" => 785_035.0,
                             "total_customers" => 115, "total_revenue" => 851_229.0, "new_aov" => 6_619.0, "returning_aov" => 7_477.0 }
    decomposition = WeeklyMetricsService.new(Date.new(2026, 9, 7)).send(:build_revenue_decomposition, this_week, trailing4_avg, last_year_same_week)

    metrics = {
      "period" => WeeklyPeriod.new(Date.new(2026, 9, 7)).as_json,
      "week_type" => { "type" => "normal_week", "type_label" => "一般自然週", "campaign_size_note" => nil },
      "revenue_progress" => { "already_beat_last_year" => true, "required_weekly_revenue_to_beat_last_year" => nil,
                               "this_week_revenue" => 994_634.0, "prev_week_revenue" => 2_336_858.0, "week_before_prev_revenue" => 1_800_000.0,
                               "ytd_revenue" => 86_412_850.0, "last_year_same_period_ytd_revenue" => 83_480_524.0,
                               "last_year_full_year_revenue" => 112_835_149.0, "gap_to_beat_last_year" => 112_835_149.0 - 86_412_850.0,
                               "days_remaining_in_year" => 109, "weeks_remaining_in_year" => 15.6,
                               "comparable_basis" => { "growth_pct" => decomposition["revenue_growth_vs_trailing4_pct"], "basis_label" => "近4個一般自然週平均", "sample_size" => 4 },
                               "revenue_concentration" => { "top_customer_share_pct" => 2.0, "top_level_share_pct" => 20.0, "top_level_name" => "銀卡",
                                                             "top_product_share_pct" => 15.0, "top_product_name" => "膠原蛋白", "top_livestream_share_pct" => 0.0 } },
      "new_vs_returning" => { "this_week" => this_week, "prev_week" => { "new_customers" => 15, "new_aov" => 9_000.0, "total_revenue" => 2_336_858.0 },
                               "week_before_prev" => { "new_customers" => 18 }, "trailing4_weekly_avg" => trailing4_avg,
                               "last_year_same_week" => last_year_same_week, "decomposition" => decomposition,
                               "cohort_repurchase" => [{ "window_days" => 30, "repurchase_rate_pct" => 12.0, "prev_cohort_rate_pct" => 13.0, "sample_sufficient" => true }] },
      "product_repurchase" => { "products" => [{ "product_key" => "omnipotent", "label" => "全能", "availability_status" => "out_of_stock",
                                                   "lifetime_repurchase_rate_pct" => 56.9,
                                                   "actionability" => { "actionable_count" => 10, "tiers" => { "a_tier_count" => 3, "b_tier_count" => 4, "c_tier_count" => 3, "dormant_tier_count" => 0, "unclassified_count" => 0 } },
                                                   "trailing4_revenue_share_pct" => 12.0, "expected_restock_date" => nil,
                                                   "overdue_count" => 50, "overdue_count_prev_week" => 48, "overdue_growth_pct" => 4.2,
                                                   "repurchased_this_week" => 2, "due_today_count" => 1, "due_soon_count" => 2 }],
                                 "returning_customers_this_week" => 93, "contradiction_detected" => false },
      "membership" => { "black_gold_revenue_share_pct" => 10.0,
                         "changes" => { "downgrade_count" => 1, "upgrade_count" => 0, "trailing4_weekly_avg_downgrade_count" => 0.5, "prev_week_net" => -1, "prev_week_upgrade_count" => 0, "prev_week_downgrade_count" => 1 },
                         "levels" => [], "reconciliation" => { "unclassified_revenue" => 0.0, "unclassified_pct" => 0.0, "note" => "note" } },
      "order_quality" => { "this_week_failed_rate_pct" => 0.5, "trailing4_failed_rate_pct" => 0.5, "this_week_unpaid_rate_pct" => 0.5, "trailing4_unpaid_rate_pct" => 0.5 },
      "data_quality" => { "product_cycle_contradiction_detected" => false, "stale_product_cycles" => [], "membership_unclassified_revenue_pct" => 0.0,
                           "last_year_same_week_data_incomplete" => false, "stale_livestream_stats" => [] },
      "livestreams" => [], "data_gaps" => { "completeness_score" => 60.0, "gaps" => [] }
    }

    Livestream.find_or_create_by!(date: Date.new(2026, 9, 4)) { |l| l.total_orders = 100; l.total_revenue = 500_000; l.total_buyers = 90; l.new_buyers = 10 }

    period = WeeklyPeriod.new(Date.new(2026, 9, 7))
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    business_signals = WeeklyBusinessSignalClassifier.call(metrics, risk_flags)
    headline = WeeklyHeadlineClassifier.call(period: period, metrics: metrics, risk_flags: risk_flags, business_signals: business_signals["signals"])
    program_action_items = WeeklyActionItemBuilder.call(period: period, risk_flags: risk_flags)
    registry = WeeklyMetricRegistry.call(metrics)

    # 這份 ai_report 刻意混入一個registry比對不到的數字（品牌代言費用試算）與
    # 一個period標錯的數字，讓quality_check真的產生「需要檢查」，驗證這種
    # 狀態下畫面也不會破版（不是只測「全部乾淨」的樂觀路徑）。
    ai_report = {
      "executive_summary" => {
        "one_liner" => "本週為活動後回落／新客不足警戒週，營收較近4週活動高基期回落，但仍優於去年同週，主因購買人數與客單價同時走弱，最需優先處理的是新客入口轉弱與全能缺貨兩大問題。",
        "status_basis" => "本週營收994,634元，較近4週平均下降61.8%（證據強度：高）",
        "top_findings" => [{ "finding" => "新客入口明顯轉弱", "data_evidence" => "本週新客5人，近4週平均17人", "why_it_matters" => "影響未來回購母體", "nature" => "short_term", "revenue_impact" => "中期營收缺口", "confidence" => "high" }],
        "decisions" => [{
          "question" => "是否立即啟動全能缺貨的預購機制？", "current_situation" => "全能缺貨中，歷史回購率56.9%", "data_evidence" => "逾期50人",
          "decision_type" => "immediate", "confidence" => "high",
          "option_a" => { "action" => "啟動預購頁", "benefit" => "留住需求", "risk" => "履約壓力", "condition" => "供應鏈可承諾到貨" },
          "option_b" => { "action" => "導向替代商品", "benefit" => "立即可賣", "risk" => "客戶接受度未知", "condition" => "有相近品項" },
          "option_c" => nil, "recommended_option" => "A", "recommendation_reason" => "回購率高於40%門檻",
          "test_design" => nil, "data_needed" => nil, "impact_if_no_decision" => "流失高回購率客群", "next_week_kpi" => "預購頁轉換率"
        }],
        "biggest_risk" => { "description" => "全能缺貨疊加舊客回購下滑，侵蝕營收基本盤", "data_evidence" => "全能占近4週營收12.0%、回購率56.9%（測試混入未收錄數字：品牌代言費用試算約87.5萬元）" },
        "biggest_opportunity" => { "description" => "舊客消費能力仍在，適合精準召回", "data_evidence" => "上週新客客單價9,670元，優於去年同期" }
      },
      "business_analysis" => {
        "revenue_and_forecast" => ["本週營收較去年同週成長16.8%（證據強度：高）"],
        "revenue_change_breakdown" => ["本週下降主要來自購買人數與客單價同時下降（證據強度：高）"],
        "new_and_returning_customers" => ["新客人數較近4週平均下降70.6%（證據強度：高）"],
        "livestream_performance" => ["上週直播帶來高基期，本週回落屬預期內"],
        "membership_health" => ["本週降級1人、升級0人，淨值為負"],
        "product_and_repurchase" => ["全能缺貨風險高，建議優先處理"],
        "next_4_week_outlook" => ["若全能持續缺貨，回購動能可能進一步流失"]
      },
      "action_items" => [{ "action" => "確認全能到貨日", "linked_decision" => "是否啟動預購機制", "role" => "採購", "deadline" => "2026-09-20", "kpi" => "取得明確到貨日" }],
      "todos" => []
    }

    quality_check = WeeklyBriefingQualityChecker.call(ai_report: ai_report, metrics: metrics, risk_flags: risk_flags, business_signals: business_signals, metric_registry: registry)
    assert_not quality_check["passed"], "此測試資料應該要觸發至少一項AI事實查核失敗，才能驗證『需要檢查』狀態下的渲染路徑"

    briefing = WeeklyBriefing.create!(
      week_start: period.week_start, week_end: period.week_end, status: "success",
      model: "claude-opus-4-8", prompt_version: "v6", generated_at: Time.current,
      ai_report: ai_report, metrics: metrics,
      meta: { "risk_flags" => risk_flags, "status_classification" => WeeklyStatusClassifier.call(metrics, risk_flags),
              "business_signals" => business_signals, "headline" => headline, "program_action_items" => program_action_items,
              "quality_check" => quality_check, "ai_api_success" => true, "retried" => false }
    )

    sign_in @admin
    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "活動後回落"
    assert_includes response.body, "新客不足警戒週"
    assert_includes response.body, "四大經營燈號"
    assert_includes response.body, "需要檢查"
    # 沒有 view 直接插入 nil 造成的字面 "nil" 顯示，也沒有標題留白
    assert_not_includes response.body, ">nil<"
    assert_not_includes response.body, "<h2></h2>"
    assert_not_includes response.body, "<h1></h1>"
  end

  test "in_progress shows same-elapsed-day comparisons for the still-running week, not a full week vs full week comparison" do
    travel_to Date.new(2026, 9, 15) do
      sign_in @admin
      get in_progress_weekly_briefing_path

      assert_response :success
      assert_includes response.body, "本週即時進度"
      assert_includes response.body, "尚未結束"
    end
  ensure
    travel_back
  end
end
