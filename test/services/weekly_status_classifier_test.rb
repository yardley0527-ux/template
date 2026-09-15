# frozen_string_literal: true

require "test_helper"

class WeeklyStatusClassifierTest < ActiveSupport::TestCase
  def metrics_with_growth(growth_pct, sample_size: 4)
    { "revenue_progress" => { "comparable_basis" => { "growth_pct" => growth_pct, "basis_label" => "近#{sample_size}個一般自然週平均", "sample_size" => sample_size } } }
  end

  test "returns insufficient_data when there is no comparable basis" do
    m = { "revenue_progress" => { "comparable_basis" => { "growth_pct" => nil } } }
    result = WeeklyStatusClassifier.call(m, [])

    assert_equal "insufficient_data", result["status"]
    assert_equal "low", result["confidence"]
  end

  test "returns healthy_growth for strong comparable-basis growth with no risk flags" do
    result = WeeklyStatusClassifier.call(metrics_with_growth(10.0), [])
    assert_equal "healthy_growth", result["status"]
  end

  test "returns flat for growth near zero with no risk flags" do
    result = WeeklyStatusClassifier.call(metrics_with_growth(1.0), [])
    assert_equal "flat", result["status"]
  end

  test "returns growth_with_concerns when growth is positive but medium risk flags exist" do
    flags = [{ key: "returning_aov_drop_vs_avg4", severity: "medium" }]
    result = WeeklyStatusClassifier.call(metrics_with_growth(5.0), flags)
    assert_equal "growth_with_concerns", result["status"]
  end

  test "returns short_term_pullback for a severe single-week drop without consecutive decline" do
    result = WeeklyStatusClassifier.call(metrics_with_growth(-20.0), [])
    assert_equal "short_term_pullback", result["status"]
  end

  test "returns structural_decline when consecutive_revenue_decline flag is present" do
    flags = [{ key: "consecutive_revenue_decline", severity: "high" }]
    result = WeeklyStatusClassifier.call(metrics_with_growth(-5.0), flags)
    assert_equal "structural_decline", result["status"]
  end

  test "returns high_risk when two or more high-severity flags are present" do
    flags = [{ key: "a", severity: "high" }, { key: "b", severity: "high" }]
    result = WeeklyStatusClassifier.call(metrics_with_growth(10.0), flags)
    assert_equal "high_risk", result["status"]
  end

  test "confidence downgrades when the comparable sample size is small" do
    result = WeeklyStatusClassifier.call(metrics_with_growth(10.0, sample_size: 1), [])
    assert_equal "low", result["confidence"]
  end
end
