# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingTest < ActiveSupport::TestCase
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

  test "accessor methods read from ai_report sections and default to empty arrays" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
                                       ai_report: { "one_liner" => "測試結論", "wins" => [{ "point" => "x" }] })

    assert_equal "測試結論", briefing.one_liner
    assert_equal [{ "point" => "x" }], briefing.wins
    assert_equal [], briefing.issues
    assert_equal [], briefing.risks
  end
end
