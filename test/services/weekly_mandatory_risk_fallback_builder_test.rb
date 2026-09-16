# frozen_string_literal: true

require "test_helper"

class WeeklyMandatoryRiskFallbackBuilderTest < ActiveSupport::TestCase
  test "returns nil when there are no uncovered topics" do
    assert_nil WeeklyMandatoryRiskFallbackBuilder.call(uncovered_topics: [])
  end

  test "builds a single-topic risk description traceable to the flag's own evidence" do
    topic = { "label" => "全能缺貨", "topic_key" => "product_stockout_risk",
              "evidence" => { "label" => "全能", "lifetime_repurchase_rate_pct" => 56.9, "reasons" => ["歷史回購率56.9%(≥40%)"] } }

    result = WeeklyMandatoryRiskFallbackBuilder.call(uncovered_topics: [topic])

    assert_equal "全能缺貨", result["description"]
    assert_includes result["data_evidence"], "56.9"
    assert result["program_generated"]
    assert_includes result["program_generated_reason"], "全能缺貨"
  end

  test "builds a compound description when two topics are uncovered together" do
    topics = [
      { "label" => "新客人數低於近4週平均", "topic_key" => "new_customer_drop_vs_avg4", "evidence" => {} },
      { "label" => "全能缺貨", "topic_key" => "product_stockout_risk", "evidence" => { "label" => "全能" } }
    ]

    result = WeeklyMandatoryRiskFallbackBuilder.call(uncovered_topics: topics)

    assert_equal "新客人數低於近4週平均與全能缺貨同時發生", result["description"]
  end

  test "does not fabricate any evidence field beyond what the flag itself carries" do
    topic = { "label" => "新客不足", "topic_key" => "new_customer_drop_vs_avg4", "evidence" => { "this_week" => 5, "trailing4_avg" => 17 } }
    result = WeeklyMandatoryRiskFallbackBuilder.call(uncovered_topics: [topic])

    assert_includes result["data_evidence"], "this_week=5"
    assert_includes result["data_evidence"], "trailing4_avg=17"
  end
end
