# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingTest < ActiveSupport::TestCase
  test "regenerating? is true right after regeneration_started_at is set" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", regeneration_started_at: Time.current)
    assert briefing.regenerating?
  end

  test "regenerating? is false once regeneration_started_at is cleared" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", regeneration_started_at: nil)
    assert_not briefing.regenerating?
  end

  test "regenerating? treats a regeneration_started_at older than REGENERATION_TIMEOUT as stale, not stuck forever" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success",
                                       regeneration_started_at: WeeklyBriefing::REGENERATION_TIMEOUT.ago - 1.minute)
    assert_not briefing.regenerating?, "a job that started over #{WeeklyBriefing::REGENERATION_TIMEOUT.inspect} ago is presumed dead (crashed/restarted), not still running"
  end

  test "week_start must be unique" do
    WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "pending")
    dup = WeeklyBriefing.new(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "pending")

    assert_not dup.valid?
    assert_includes dup.errors[:week_start], "has already been taken"
  end

  test "for_week finds the existing row instead of creating a duplicate" do
    existing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success")

    found = WeeklyBriefing.for_week(Date.new(2026, 6, 15))
    assert_equal existing.id, found.id
    assert_not found.new_record?
  end

  test "history orders newest week first" do
    old = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 1), week_end: Date.new(2026, 6, 7), status: "success")
    newer = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success")

    assert_equal [newer, old], WeeklyBriefing.history.to_a
  end

  test "accessor methods read from the new executive_summary/business_analysis sections and default to empty arrays" do
    briefing = WeeklyBriefing.create!(
      week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
      ai_report: {
        "executive_summary" => { "status" => "flat", "status_label" => "大致持平", "one_liner" => "測試結論" },
        "business_analysis" => { "revenue_and_forecast" => ["bullet"] },
        "action_items" => [{ "action" => "x" }]
      }
    )

    assert_equal "測試結論", briefing.one_liner
    assert_equal "flat", briefing.business_status
    assert_equal "大致持平", briefing.business_status_label
    assert_equal ["bullet"], briefing.business_analysis["revenue_and_forecast"]
    assert_equal [{ "action" => "x" }], briefing.action_items
    assert_equal [], briefing.top_findings
    assert_equal [], briefing.decisions
  end

  test "the AR status column is not shadowed by the business_status accessor" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 7, 1), week_end: Date.new(2026, 7, 7), status: "failed")

    assert_equal "failed", briefing.status
    assert_nil briefing.business_status
  end
end
