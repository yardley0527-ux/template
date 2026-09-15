# frozen_string_literal: true

require "test_helper"

class WeeklyWeekTypeClassifierTest < ActiveSupport::TestCase
  def period_for(date)
    WeeklyPeriod.new(date)
  end

  test "classifies a week with a livestream as livestream_week" do
    period = period_for(Date.new(2026, 6, 15))
    Livestream.create!(date: period.week_start + 1)

    result = WeeklyWeekTypeClassifier.call(period)
    assert_equal "livestream_week", result["type"]
    assert_equal [period.week_start + 1], result["livestream_dates"]
  end

  test "classifies a week with a campaign calendar event as campaign_week" do
    period = period_for(Date.new(2026, 6, 15))
    CalendarEvent.create!(title: "中秋活動", event_type: "campaign", event_date: period.week_start + 2)

    result = WeeklyWeekTypeClassifier.call(period)
    assert_equal "campaign_week", result["type"]
    assert result["campaign_size_note"].present?
  end

  test "classifies a week with both a livestream and a campaign as livestream_and_campaign_week" do
    period = period_for(Date.new(2026, 6, 15))
    Livestream.create!(date: period.week_start + 1)
    CalendarEvent.create!(title: "活動", event_type: "campaign", event_date: period.week_start + 2)

    assert_equal "livestream_and_campaign_week", WeeklyWeekTypeClassifier.call(period)["type"]
  end

  test "classifies a week with neither as normal_week" do
    period = period_for(Date.new(2026, 6, 15))
    assert_equal "normal_week", WeeklyWeekTypeClassifier.call(period)["type"]
  end

  test "comparable_week_starts for a normal week only returns other normal weeks, most recent first" do
    period = period_for(Date.new(2026, 6, 15))
    # 1 week back: normal (should match)
    # 2 weeks back: livestream (should be excluded)
    Livestream.create!(date: period.week_start - 14 + 1)

    starts = WeeklyWeekTypeClassifier.comparable_week_starts(period, count: 4, lookback_weeks: 8)

    assert_includes starts, period.week_start - 7
    assert_not_includes starts, period.week_start - 14
  end

  test "comparable_week_starts for a livestream week only returns other livestream weeks" do
    period = period_for(Date.new(2026, 6, 15))
    Livestream.create!(date: period.week_start + 1) # this week is a livestream week
    Livestream.create!(date: period.week_start - 21 + 1) # 3 weeks back also has a livestream

    starts = WeeklyWeekTypeClassifier.comparable_week_starts(period, count: 4, lookback_weeks: 8)

    assert_includes starts, period.week_start - 21
    assert_not_includes starts, period.week_start - 7 # normal week, should not match a livestream week's basis
  end
end
