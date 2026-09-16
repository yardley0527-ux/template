# frozen_string_literal: true

require "test_helper"

# 用「上一輪真實Claude API呼叫」實際存下來的完整回應（見weekly_briefing_service.rb
# 的live測試腳本，內容已在對話中確認過是全合成的regression-fixture數字，
# 不含任何API key／request header／使用者個資）做回歸測試——不重打API，
# 直接拿當時的AI輸出文字驗證這輪修正後的結果。
#
# 驗證兩件事：
#   1. 上一輪那8個invalid，這次跑同一份文字應該全部變成verified或有理由
#      的not_checked，一個都不留在invalid
#   2. 人工在這份真實回應上植入6種錯誤（不存在的營收/本週上週對調/上升
#      寫成下降/新客紅燈寫成綠燈/商品回購率被竄改/衍生差額算錯），全部
#      仍然要被抓成invalid——證明不是把檢查關掉了，是把檢查做對了
class WeeklyAiFactValidatorRealResponseRegressionTest < ActiveSupport::TestCase
  def build_registry(metrics)
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    status = WeeklyStatusClassifier.call(metrics, risk_flags)
    business_signals = WeeklyBusinessSignalClassifier.call(metrics, risk_flags)
    period = WeeklyPeriod.new(Date.new(2026, 9, 7))
    headline = WeeklyHeadlineClassifier.call(period: period, metrics: metrics, risk_flags: risk_flags, business_signals: business_signals["signals"])
    labeled_flags = risk_flags.map do |f|
      f.merge(severity_label: WeeklyRiskFlagDetector::SEVERITY_LABELS[f[:severity]],
              category_label: WeeklyRiskFlagDetector::CATEGORY_LABELS[f[:category]],
              label: WeeklyRiskFlagDetector::KEY_LABELS[f[:key]])
    end
    context = { "metrics" => metrics, "status" => status, "risk_flags" => labeled_flags, "business_signals" => business_signals, "headline" => headline }
    { registry: WeeklyMetricRegistry.call(metrics).merge(WeeklyAiContextValueIndex.call(context)), business_signals: business_signals }
  end

  def fixture_metrics
    this_week = { "new_customers" => 5, "returning_customers" => 93, "new_revenue" => 48_349.0, "returning_revenue" => 946_285.0,
                   "total_customers" => 98, "total_revenue" => 994_634.0, "new_aov" => 9_670.0, "returning_aov" => 10_175.0,
                   "new_pct" => (5 * 100.0 / 98) }
    trailing4_avg = { "new_customers" => 17, "returning_customers" => 137, "new_revenue" => 177_137.0, "returning_revenue" => 2_426_820.0,
                       "total_customers" => 154, "total_revenue" => 2_603_957.0, "new_aov" => 10_420.0, "returning_aov" => 17_714.0 }
    last_year_same_week = { "new_customers" => 10, "returning_customers" => 105, "new_revenue" => 66_194.0, "returning_revenue" => 785_035.0,
                             "total_customers" => 115, "total_revenue" => 851_229.0, "new_aov" => 6_619.0, "returning_aov" => 7_477.0 }
    decomposition = WeeklyMetricsService.new(Date.new(2026, 9, 7)).send(:build_revenue_decomposition, this_week, trailing4_avg, last_year_same_week)

    {
      "period" => WeeklyPeriod.new(Date.new(2026, 9, 7)).as_json,
      "week_type" => { "type" => "normal_week", "type_label" => "一般自然週", "campaign_size_note" => nil },
      "revenue_progress" => {
        "already_beat_last_year" => true, "required_weekly_revenue_to_beat_last_year" => nil,
        "this_week_revenue" => 994_634.0, "prev_week_revenue" => 2_336_858.0, "week_before_prev_revenue" => 1_800_000.0,
        "ytd_revenue" => 86_412_850.0, "last_year_same_period_ytd_revenue" => 83_480_524.0,
        "last_year_full_year_revenue" => 112_835_149.0, "gap_to_beat_last_year" => 112_835_149.0 - 86_412_850.0,
        "days_remaining_in_year" => 109, "weeks_remaining_in_year" => 15.6,
        "comparable_basis" => { "growth_pct" => decomposition["revenue_growth_vs_trailing4_pct"], "basis_label" => "近4個一般自然週平均", "sample_size" => 4 },
        "revenue_concentration" => { "top_customer_share_pct" => 2.0, "top_level_share_pct" => 20.0, "top_level_name" => "銀卡",
                                      "top_product_share_pct" => 15.0, "top_product_name" => "膠原蛋白", "top_livestream_share_pct" => 0.0 }
      },
      "new_vs_returning" => {
        "this_week" => this_week, "prev_week" => { "new_customers" => 15, "new_aov" => 9_000.0, "total_revenue" => 2_336_858.0 },
        "week_before_prev" => { "new_customers" => 18 }, "trailing4_weekly_avg" => trailing4_avg,
        "last_year_same_week" => last_year_same_week, "decomposition" => decomposition,
        "cohort_repurchase" => [{ "window_days" => 30, "repurchase_rate_pct" => 12.0, "prev_cohort_rate_pct" => 13.0, "sample_sufficient" => true }]
      },
      "product_repurchase" => {
        "products" => [
          { "product_key" => "omnipotent", "label" => "全能", "availability_status" => "out_of_stock",
            "lifetime_repurchase_rate_pct" => 56.9,
            "actionability" => { "actionable_count" => 10, "tiers" => { "a_tier_count" => 3, "b_tier_count" => 4, "c_tier_count" => 3, "dormant_tier_count" => 0, "unclassified_count" => 0 } },
            "trailing4_revenue_share_pct" => 12.0, "expected_restock_date" => nil,
            "overdue_count" => 50, "overdue_count_prev_week" => 48, "overdue_growth_pct" => 4.2,
            "repurchased_this_week" => 2, "due_today_count" => 1, "due_soon_count" => 2 }
        ],
        "returning_customers_this_week" => 93, "contradiction_detected" => false
      },
      "membership" => {
        "black_gold_revenue_share_pct" => 10.0,
        "changes" => { "downgrade_count" => 1, "upgrade_count" => 0, "trailing4_weekly_avg_downgrade_count" => 0.5, "prev_week_net" => -1, "prev_week_upgrade_count" => 0, "prev_week_downgrade_count" => 1 },
        "levels" => [], "reconciliation" => { "unclassified_revenue" => 0.0, "unclassified_pct" => 0.0, "note" => "note" }
      },
      "order_quality" => { "this_week_failed_rate_pct" => 0.5, "trailing4_failed_rate_pct" => 0.5, "this_week_unpaid_rate_pct" => 0.5, "trailing4_unpaid_rate_pct" => 0.5 },
      "data_quality" => { "product_cycle_contradiction_detected" => false, "stale_product_cycles" => [], "membership_unclassified_revenue_pct" => 0.0,
                           "last_year_same_week_data_incomplete" => false, "stale_livestream_stats" => [] },
      "livestreams" => [], "data_gaps" => { "completeness_score" => 60.0, "gaps" => [] }
    }
  end

  # 上一輪真實API回應的 ai_report（原封不動的文字內容，全合成測試數字）。
  def real_ai_report
    {
      "executive_summary" => {
        "one_liner" => "本週為活動後回落／新客不足警戒週，營收較活動高基期回落且新客連兩週下滑，是雙重衰退中的高風險週；但相較去年同週仍成長16.85%，最需優先處理的是新客入口轉弱與全能缺貨風險。",
        "biggest_risk" => {
          "description" => "高回購商品全能缺貨且無到貨日，疊加新客連兩週下滑，回購與拉新兩端同時承壓",
          "data_evidence" => "全能回購率56.9%、占近4週營收12%、逾期50人；新客18→15→5人，較近4週-70.6%。"
        },
        "biggest_opportunity" => {
          "description" => "YTD營收已超越去年同期，且舊客客單價年增顯著，維穩既有客回購可鞏固年度領先",
          "data_evidence" => "YTD 86,412,850元 vs 去年同期83,480,524元；舊客客單價年增36.08%、舊客營收年增20.54%。"
        },
        "decisions" => [
          {
            "question" => "全能缺貨要不要立即啟動預購與到貨通知機制？",
            "current_situation" => "全能缺貨中且無預計到貨日，逾期未回購50人、本週due_today 1人、due_soon 2人，占近4週營收12%。",
            "data_evidence" => "歷史回購率56.9%、逾期人數週增4.2%（48→50人），本週僅回購2人。",
            "recommendation_reason" => "全能回購率高達56.9%且占近4週營收12%，逾期名單週增4.2%，優先鎖客的效益高於分散推薦。",
            "impact_if_no_decision" => "逾期50人持續累積且無承接方案，高回購客群恐流失至競品。"
          },
          {
            "question" => "新客連兩週下滑，要不要小規模測試首購入口？",
            "current_situation" => "新客5人、佔比5.1%，連續兩週下降，新客營收48,349元遠低於近4週平均177,137元。",
            "data_evidence" => "新客18→15→5人，較近4週-70.6%；新客客單價9,670元反而高於上週9,000元，顯示成交客質量尚可、問題在入口人數。",
            "recommendation_reason" => "新客客單價9,670元仍高於上週，代表成交端未惡化，問題偏向入口人數，小額測試可快速定位是流量或轉換問題。",
            "impact_if_no_decision" => "新客入口若持續轉弱，未來回購與會員池基數縮減。"
          }
        ]
      },
      "business_analysis" => {
        "revenue_and_forecast" => [
          "本週為活動後回落週，營收NT$994,634較近4週平均-61.8%，屬紅燈（證據強度：高）。",
          "但相較去年同週851,229元仍成長16.85%，不宜僅因活動高基期就判定為全面衰退（證據強度：高）。",
          "YTD營收86,412,850元已超越去年同期83,480,524元，年度領先2,932,326元；距離超越去年全年112,835,149元尚差26,422,299元，剩15.57週（證據強度：高）。",
          "以年度進度看，維持既有回購動能即有機會挑戰去年全年，關鍵在避免週營收持續落在百萬以下（證據強度：中）。"
        ],
        "revenue_change_breakdown" => [
          "本週營收下降主要來自購買人數與客單價同時下降（雙重衰退）：購買人數較近4週-36.36%、整體客單價-39.98%（證據強度：高）。",
          "分項看，新客人數-70.6%、舊客人數-32.1%皆走弱；舊客客單價由近4週17,714元降至10,175元（-42.6%），是客單價下降的主要來源之一（證據強度：高）。",
          "上週活動高基期造成的客單價與人數同步墊高，是本週回落幅度放大的可能原因，但CRM尚無法區分回落中屬正常活動退潮或需求轉弱的比例（證據強度：中）。"
        ],
        "new_and_returning_customers" => [
          "新客入口明顯轉弱：新客由18→15→5人，較近4週平均-70.6%，佔比僅5.1%（證據強度：高）。CRM目前無法區分是站外流量下降或站內轉換下降，建議先檢查既有拉新入口，下週追蹤新客人數與新客營收。",
          "新客客單價9,670元反高於上週9,000元，顯示成交客質量未惡化，問題集中在入口人數（證據強度：中）。",
          "舊客回購93人，較近4週平均137人-32.1%，為紅燈；舊客客單價10,175元較近4週-42.6%（證據強度：高）。",
          "值得注意的是舊客營收較去年同週仍成長20.54%、舊客客單價年增36.08%，代表既有客單客價值相較去年是提升的，本週的弱勢主要對比對象是活動高基期（證據強度：中）。"
        ]
      },
      "action_items" => [
        { "action" => "開放全能預購並對50位逾期客發送到貨通知登記", "linked_decision" => "決策一：全能缺貨處理",
          "role" => "商品／庫存負責人", "deadline" => "2026-09-16", "kpi" => "到貨通知登記數、逾期未回購人數止升" },
        { "action" => "對逾期全能客群推薦合適替代商品維持回購關係", "linked_decision" => "決策一：全能缺貨處理",
          "role" => "CRM／會員經營", "deadline" => "2026-09-18", "kpi" => "替代商品回購轉換數" },
        { "action" => "在既有拉新入口小額測試首購優惠並分段追蹤到站至結帳", "linked_decision" => "決策二：新客入口測試",
          "role" => "行銷負責人", "deadline" => "2026-09-20", "kpi" => "新客人數回升至≥9人、各段轉換率" },
        { "action" => "盤點連兩週淨降級名單，針對銀卡以上主力客啟動維繫溝通", "linked_decision" => "top_finding：會員淨降級連兩週",
          "role" => "會員經營", "deadline" => "2026-09-20", "kpi" => "淨降級人數轉正、主力卡別活躍回購率" }
      ]
    }
  end

  test "all 8 previously-invalid issues from the real API response are now verified or reasoned not_checked, zero remain invalid" do
    built = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(ai_report: real_ai_report, registry: built[:registry])

    assert_empty result["issues"], "expected zero invalid issues, got: #{result['issues'].inspect}"
    assert result["passed"]

    # 原本8個裡有5個涉及的數字（2,932,326 / -42.6 / 三次9,670）現在不會出現
    # 在issues清單，"9"（kpi目標值）也不會，"5"/"5.1"也不會。
    flagged_values = result["issues"].map { |i| i["ai_value"] }
    assert_not_includes flagged_values, "2,932,326"
    assert_not_includes flagged_values, "-42.6"
    assert_not_includes flagged_values, "9,670"
    assert_not_includes flagged_values, "9"
    assert_not_includes flagged_values, "5"
    assert_not_includes flagged_values, "5.1"
  end

  # ── 人工植入6種錯誤，逐一確認仍被抓成invalid（不是關掉檢查）────────
  test "INJECTED ERROR 1: a fabricated revenue number that never appeared in the real response still gets flagged" do
    built = build_registry(fixture_metrics)
    tampered = real_ai_report.deep_dup
    tampered["executive_summary"]["biggest_risk"]["data_evidence"] += "本週另有一筆隱藏營收3,141,592元未列入計算。"

    result = WeeklyAiFactValidator.call(ai_report: tampered, registry: built[:registry])

    assert_not result["passed"]
    assert result["issues"].any? { |i| i["ai_value"] == "3,141,592" && i["kind"] == "unverified_number" }, result["issues"].inspect
  end

  test "INJECTED ERROR 2: swapping this-week and last-week revenue labels is still caught" do
    built = build_registry(fixture_metrics)
    tampered = real_ai_report.deep_dup
    tampered["business_analysis"]["revenue_and_forecast"] = ["上週營收994,634元，較近4週平均明顯偏低"]

    result = WeeklyAiFactValidator.call(ai_report: tampered, registry: built[:registry])

    assert_not result["passed"]
    issue = result["issues"].find { |i| i["kind"] == "period_mismatch" && i["ai_value"] == "994,634" }
    assert issue, result["issues"].inspect
    assert_equal "上週", issue["claimed_period"]
    assert_equal "本週", issue["actual_period"]
  end

  test "INJECTED ERROR 3: writing a decline as an increase (direction reversed) is still caught" do
    built = build_registry(fixture_metrics)
    tampered = real_ai_report.deep_dup
    tampered["business_analysis"]["revenue_change_breakdown"] = ["本週購買人數較近4週平均上升36.36%，表現轉強"]

    result = WeeklyAiFactValidator.call(ai_report: tampered, registry: built[:registry])

    assert_not result["passed"]
    assert result["issues"].any? { |i| i["kind"] == "direction_mismatch" && i["ai_value"] == "36.36" }, result["issues"].inspect
  end

  test "INJECTED ERROR 4: claiming the new-customer signal is green when the program computed it as red is still caught (via quality checker's signal-contradiction check)" do
    metrics = fixture_metrics
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    business_signals = WeeklyBusinessSignalClassifier.call(metrics, risk_flags)
    tampered = real_ai_report.deep_dup
    tampered["business_analysis"]["new_and_returning_customers"] = ["新客表現正常，較近4週平均無明顯變化"]

    quality = WeeklyBriefingQualityChecker.call(ai_report: tampered, metrics: metrics, risk_flags: risk_flags, business_signals: business_signals)

    assert_not quality["passed"]
    assert quality["failed_items"].any? { |f| f.include?("安心話術") }, quality["failed_items"].inspect
  end

  test "INJECTED ERROR 5: tampering with the product repurchase rate to a nonexistent value is still caught" do
    built = build_registry(fixture_metrics)
    tampered = real_ai_report.deep_dup
    tampered["executive_summary"]["biggest_risk"]["data_evidence"] = "全能回購率90.0%、占近4週營收12%、逾期50人。"

    result = WeeklyAiFactValidator.call(ai_report: tampered, registry: built[:registry])

    assert_not result["passed"]
    assert result["issues"].any? { |i| i["ai_value"] == "90.0" && i["kind"] == "unverified_number" }, result["issues"].inspect
  end

  test "INJECTED ERROR 6: a miscalculated derived YTD-lead figure is still caught, proving the derived_metric fix doesn't wave through wrong numbers" do
    built = build_registry(fixture_metrics)
    tampered = real_ai_report.deep_dup
    tampered["business_analysis"]["revenue_and_forecast"] = ["YTD營收86,412,850元已超越去年同期83,480,524元，年度領先5,000,000元"]

    result = WeeklyAiFactValidator.call(ai_report: tampered, registry: built[:registry])

    assert_not result["passed"]
    assert result["issues"].any? { |i| i["ai_value"] == "5,000,000" && i["kind"] == "unverified_number" }, result["issues"].inspect
  end
end
