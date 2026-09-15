# frozen_string_literal: true

require "test_helper"

class WeeklyPeriodTest < ActiveSupport::TestCase
  test "week_start is always the Monday on or before the reference date" do
    # 2026-09-15 is a Tuesday
    period = WeeklyPeriod.new(Date.new(2026, 9, 15))
    assert_equal Date.new(2026, 9, 14), period.week_start
    assert_equal Date.new(2026, 9, 20), period.week_end
  end

  test "a Monday reference date is its own week_start" do
    period = WeeklyPeriod.new(Date.new(2026, 9, 14))
    assert_equal Date.new(2026, 9, 14), period.week_start
  end

  test "prev_week and trailing4 do not overlap the current week" do
    period = WeeklyPeriod.new(Date.new(2026, 9, 14))
    assert_equal Date.new(2026, 9, 7), period.prev_week_start
    assert_equal Date.new(2026, 9, 13), period.prev_week_end
    assert_equal Date.new(2026, 8, 17), period.trailing4_start
    assert_equal Date.new(2026, 9, 13), period.trailing4_end
    assert_not period.trailing4_range.cover?(period.week_start)
  end

  test "ytd starts at January 1st of the week_end's year" do
    period = WeeklyPeriod.new(Date.new(2026, 9, 14))
    assert_equal Date.new(2026, 1, 1), period.ytd_start
  end

  test "last_year_same_week_start falls back a day when last year has no matching Feb 29" do
    # 2016-02-29 was itself a Monday (Jan 1 2016 was a Friday), so week_start == 2016-02-29 exactly.
    period = WeeklyPeriod.new(Date.new(2016, 2, 29))
    assert_equal Date.new(2016, 2, 29), period.week_start

    # 2015 is not a leap year: Date.new(2015, 2, 29) would raise, must fall back to 2/28.
    assert_equal Date.new(2015, 2, 28), period.last_year_same_week_start
  end

  test "days_remaining_in_year is zero when the week ends exactly on Dec 31" do
    # 2023-12-25 was a Monday and 2023-12-31 a Sunday, so this week ends exactly on Dec 31 (no year spillover).
    period = WeeklyPeriod.new(Date.new(2023, 12, 25))
    assert_equal Date.new(2023, 12, 31), period.week_end
    assert_equal 0, period.days_remaining_in_year
  end

  test "a week straddling the New Year boundary keys ytd/days_remaining off week_end's year" do
    # 2026-12-31 is a Thursday, so its Mon-Sun week spills into the next year (week_end = 2027-01-03).
    period = WeeklyPeriod.new(Date.new(2026, 12, 31))
    assert_equal Date.new(2027, 1, 3), period.week_end
    assert_equal Date.new(2027, 1, 1), period.ytd_start
    assert period.days_remaining_in_year > 360
  end

  test "for_week_start builds the same period as new" do
    a = WeeklyPeriod.new(Date.new(2026, 9, 14))
    b = WeeklyPeriod.for_week_start(Date.new(2026, 9, 14))
    assert_equal a.week_start, b.week_start
    assert_equal a.week_end, b.week_end
  end
end
