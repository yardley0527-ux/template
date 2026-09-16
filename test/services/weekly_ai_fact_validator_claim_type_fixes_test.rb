# frozen_string_literal: true

require "test_helper"

# 2026-09-16收斂修正：上一輪真實API呼叫產生了8個invalid，逐一人工追蹤後
# 發現全部都是validator本身的限制（不是AI真的杜撰），這裡針對每一個各自
# 建一個獨立、可重現的回歸測試——不是挑幾個代表性案例，8項全部都要有。
#
# 每個測試的註解依使用者要求的格式記錄：
#   欄位路徑 / AI原文 / 被抓數字 / 實際類型 / 對應context path或計算來源 /
#   現在（修正前）誤判原因 / 修正後預期結果
class WeeklyAiFactValidatorClaimTypeFixesTest < ActiveSupport::TestCase
  # 跟正式站 WeeklyBriefingService#call 同一套組裝方式：手動registry＋
  # 自動context index合併，確保測試環境跟正式環境用同一份allowed values。
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
    WeeklyMetricRegistry.call(metrics).merge(WeeklyAiContextValueIndex.call(context))
  end

  # 完整重建上一輪真實API呼叫用的2026/09/07~09/13 fixture（跟
  # weekly_fixture_2026_09_07_integration_test.rb同一份規格書數字，
  # 這裡額外補上revenue_progress的YTD欄位跟product_repurchase的全能明細，
  # 因為這8個false positive有幾個直接跟這兩塊資料有關）。
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

  def report(field_hash)
    {
      "executive_summary" => { "biggest_risk" => {}, "biggest_opportunity" => {}, "decisions" => [] },
      "business_analysis" => { "revenue_and_forecast" => [], "revenue_change_breakdown" => [], "new_and_returning_customers" => [] },
      "action_items" => []
    }.deep_merge(field_hash)
  end

  # ── #1 ──────────────────────────────────────────────────────────
  # 欄位: business_analysis.revenue_and_forecast[2]
  # AI原文: "YTD營收86,412,850元已超越去年同期83,480,524元，年度領先2,932,326元"
  # 被抓數字: 2,932,326
  # 實際類型: derived_metric（ytd_revenue - last_year_same_period_ytd_revenue）
  # 對應計算來源: revenue_progress.ytd(86,412,850) - revenue_progress.last_year_same_period(83,480,524)
  # 修正前誤判原因: validator只比對「context裡字面存在的數字」，衍生差額本身沒被索引
  # 修正後預期: WeeklyMetricRegistry新增derived_metric登記此差額，應verified
  test "#1 YTD lead over last year (derived difference) is now verified via the precomputed derived_metric" do
    registry = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("business_analysis" => { "revenue_and_forecast" => ["YTD營收86,412,850元已超越去年同期83,480,524元，年度領先2,932,326元"] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
    entry = registry["revenue_progress.ytd_lead_over_last_year_same_period"]
    assert_equal "derived_metric", entry["claim_type"]
    assert_equal "revenue_progress.ytd - revenue_progress.last_year_same_period", entry["formula"]
  end

  # ── #2 ──────────────────────────────────────────────────────────
  # 欄位: business_analysis.revenue_change_breakdown[1]
  # AI原文: "舊客客單價由近4週17,714元降至10,175元（-42.6%）"
  # 被抓數字: -42.6
  # 實際類型: observed_metric（returning_aov相對trailing4的跌幅），但該欄位
  #   過去完全沒被WeeklyMetricsService計算，registry裡沒有任何正確候選
  # 對應計算來源: new_vs_returning.decomposition.returning_aov_growth_vs_trailing4_pct（本輪新增）
  # 修正前誤判原因: 指標本身沒算過，auto-index只撿到risk_flags旗標證據裡
  #   用「正值代表跌幅」慣例存的drop_pct，跟「負值=下降」號慣例衝突，方向誤判
  # 修正後預期: weekly_metrics_service.rb補上這個成長率欄位後，應verified
  test "#2 returning AOV decline vs trailing4 is now verified after adding the missing metric" do
    metrics = fixture_metrics
    assert metrics.dig("new_vs_returning", "decomposition", "returning_aov_growth_vs_trailing4_pct").present?,
           "returning_aov_growth_vs_trailing4_pct should now be computed"

    registry = build_registry(metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("business_analysis" => { "revenue_change_breakdown" => ["舊客客單價由近4週17,714元降至10,175元（-42.6%），是客單價下降的主要來源之一"] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
  end

  # ── #3/#4/#5（同一種句型，三個欄位各出現一次）───────────────────
  # 欄位: business_analysis.new_and_returning_customers[1] /
  #       executive_summary.decisions[1].data_evidence /
  #       executive_summary.decisions[1].recommendation_reason
  # AI原文: "新客客單價9,670元反而高於上週9,000元"
  # 被抓數字: 9,670（誤判），9,000（原本就正確）
  # 實際類型: observed_metric，9,670=本週(new_customer.aov.this_week)，
  #   9,000=上週(自動索引 new_vs_returning.prev_week.new_aov)
  # 對應context path: new_customer.aov.this_week (9670) / 自動索引路徑
  #   metrics.new_vs_returning.prev_week.new_aov (9000)
  # 修正前誤判原因: 固定字元窗口比對，同句兩個數字時「上週」被錯配給
  #   離它較遠的9,670，而不是真正修飾的9,000
  # 修正後預期: 改用「離期間詞最近的數字」判斷歸屬，9,670不再被錯配上週，
  #   應verified；9,000本來就沒被誤判，維持verified
  test "#3 a same-sentence two-number comparison attaches the period word to the nearer number, not the farther one" do
    registry = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("business_analysis" => { "new_and_returning_customers" => ["新客客單價9,670元反而高於上週9,000元"] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
  end

  test "#4 same fix applies to executive_summary.decisions[].data_evidence" do
    registry = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("executive_summary" => { "decisions" => [
        { "current_situation" => "c", "data_evidence" => "新客18→15→5人，較近4週-70.6%；新客客單價9,670元反而高於上週9,000元，顯示成交客質量尚可",
          "recommendation_reason" => "r", "impact_if_no_decision" => "i" }
      ] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
  end

  # ── #5 ──────────────────────────────────────────────────────────
  # AI原文（無明確第二個比較數字的版本）: "新客客單價9,670元仍高於上週，代表成交端未惡化"
  # 這句「上週」沒有緊跟著的比較數字，句法上是隱含比較——9,670離「上週」
  # 的距離已經超過信心範圍（CONFIDENT_ATTACH_DISTANCE），修正後預期降級成
  # not_checked（誠實標「無法確定」，不是verified也不是invalid）。
  test "#5 an implicit same-sentence comparison with no adjacent second number is downgraded to not_checked, not silently verified or wrongly invalid" do
    registry = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("executive_summary" => { "decisions" => [
        { "current_situation" => "c", "data_evidence" => "d",
          "recommendation_reason" => "新客客單價9,670元仍高於上週，代表成交端未惡化，問題偏向入口人數",
          "impact_if_no_decision" => "i" }
      ] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
    assert result["not_checked"].any? { |i| i["ai_value"] == "9,670" && i["kind"] == "ambiguous_reference" },
           result["not_checked"].inspect
  end

  # ── #6/#7 ───────────────────────────────────────────────────────
  # 欄位: executive_summary.decisions[1].current_situation
  # AI原文: "新客5人、佔比5.1%，連續兩週下降"
  # 被抓數字: 5, 5.1
  # 實際類型: observed_metric（5=new_customer.count.this_week，
  #   5.1=new_vs_returning.this_week.new_pct的自動索引），都是對的
  # 修正前誤判原因: auto-index把risk_flags旗標證據裡的
  #   decomposition.decline_threshold_pct=5（規則門檻常數，不是本週觀測值）
  #   也當成percent候選收進同一個池子，跟「新客5人」同量級碰撞，被direction
  #   check誤判成矛盾
  # 修正後預期: WeeklyAiContextValueIndex把含threshold的欄位標成
  #   rule_threshold，validator預設排除在比對候選外，應verified
  test "#6/#7 a headcount/percentage that collides in magnitude with a rule_threshold constant is no longer misjudged" do
    registry = build_registry(fixture_metrics)
    threshold_entry = registry.values.find { |e| e["metric_key"].to_s.include?("threshold_pct") }
    assert threshold_entry, "expected at least one rule_threshold entry to exist in the merged registry for this fixture"
    assert_equal "rule_threshold", threshold_entry["claim_type"]

    result = WeeklyAiFactValidator.call(
      ai_report: report("executive_summary" => { "decisions" => [
        { "current_situation" => "新客5人、佔比5.1%，連續兩週下降", "data_evidence" => "d",
          "recommendation_reason" => "r", "impact_if_no_decision" => "i" }
      ] }),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
    assert_not result["issues"].any? { |i| i["ai_value"] == "5" }
    assert_not result["issues"].any? { |i| i["ai_value"] == "5.1" }
  end

  # ── #8 ──────────────────────────────────────────────────────────
  # 欄位: action_items[2].kpi
  # AI原文: "新客人數回升至≥9人、各段轉換率"
  # 被抓數字: 9
  # 實際類型: target_metric（AI自訂的未來KPI目標，不是對歷史事實的引用）
  # 修正前誤判原因: 把kpi欄位當成一般事實欄位，拿9去跟歷史allowed values
  #   比對，目標值本來就不該出現在歷史資料裡，找不到就被判invalid
  # 修正後預期: action_items[].kpi改走target_metric流程，不比對歷史，
  #   非負值歸類not_checked監控，不影響quality_passed
  test "#8 a KPI target number in action_items[].kpi is no longer checked against historical facts" do
    registry = build_registry(fixture_metrics)
    result = WeeklyAiFactValidator.call(
      ai_report: report("action_items" => [{ "action" => "a", "kpi" => "新客人數回升至≥9人、各段轉換率" }]),
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
    assert result["not_checked"].any? { |i| i["kind"] == "target_metric" && i["ai_value"] == "9" }, result["not_checked"].inspect
  end
end
