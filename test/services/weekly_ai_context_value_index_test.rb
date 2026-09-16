# frozen_string_literal: true

require "test_helper"

class WeeklyAiContextValueIndexTest < ActiveSupport::TestCase
  def sample_context
    {
      "metrics" => {
        "product_repurchase" => {
          "products" => [
            { "product_key" => "omnipotent", "label" => "全能", "lifetime_repurchase_rate_pct" => 56.9,
              "actionability" => { "actionable_count" => 10 }, "overdue_count" => 2995 }
          ]
        },
        "new_vs_returning" => { "this_week" => { "new_customers" => 5, "total_revenue" => 994_634.0 } }
      }
    }
  end

  test "indexes a deeply nested numeric leaf by its full JSON path" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    key = entries.keys.find { |k| k.end_with?("lifetime_repurchase_rate_pct") }

    assert key, entries.keys.inspect
    assert_equal 56.9, entries[key]["raw_value"]
  end

  test "attaches the enclosing hash's label as scope for its numeric descendants" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    entry = entries.values.find { |e| e["raw_value"] == 56.9 }

    assert_equal "全能", entry["scope"]
  end

  test "propagates scope into a nested hash below the product (e.g. actionability.actionable_count)" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    entry = entries.values.find { |e| e["raw_value"] == 10.0 }

    assert entry, "expected to find the actionable_count=10 entry"
    assert_equal "全能", entry["scope"]
  end

  test "infers period from a this_week path segment" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    entry = entries.values.find { |e| e["raw_value"] == 994_634.0 }

    assert_equal "本週", entry["period"]
  end

  test "a field with no period-hinting path segment gets a nil period, not a guessed one" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    entry = entries.values.find { |e| e["raw_value"] == 2995.0 }

    assert_nil entry["period"]
  end

  test "infers percent kind from a _pct field suffix" do
    entries = WeeklyAiContextValueIndex.call(sample_context)
    entry = entries.values.find { |e| e["raw_value"] == 56.9 }

    assert_equal "percent", entry["kind"]
    assert_equal 0.1, entry["accepted_rounding"]
  end

  test "handles an empty context without raising" do
    assert_equal({}, WeeklyAiContextValueIndex.call({}))
    assert_equal({}, WeeklyAiContextValueIndex.call(nil))
  end

  # ── claim_type：rule_threshold vs observed_metric ───────────────
  test "tags a field ending in _threshold_pct as rule_threshold, not observed_metric" do
    context = { "evidence" => { "warn_threshold_pct" => 20, "critical_threshold_pct" => 30, "current" => 5 } }
    entries = WeeklyAiContextValueIndex.call(context)

    assert_equal "rule_threshold", entries["evidence.warn_threshold_pct"]["claim_type"]
    assert_equal "rule_threshold", entries["evidence.critical_threshold_pct"]["claim_type"]
    assert_equal "observed_metric", entries["evidence.current"]["claim_type"]
  end

  test "a decomposition-style decline_threshold_pct constant is also tagged rule_threshold" do
    context = { "metrics" => { "new_vs_returning" => { "decomposition" => { "decline_threshold_pct" => 5 } } } }
    entries = WeeklyAiContextValueIndex.call(context)

    entry = entries.values.find { |e| e["raw_value"] == 5.0 }
    assert_equal "rule_threshold", entry["claim_type"]
  end
end
