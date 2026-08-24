# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class LivestreamScheduleGapTest < ActiveSupport::TestCase
    test "no notification when the last livestream was recent" do
      Livestream.create!(date: 5.days.ago.to_date)
      assert_empty LivestreamScheduleGap.call
    end

    test "P2 when gap is between the P2 and P1 thresholds and nothing is scheduled" do
      Livestream.create!(date: 15.days.ago.to_date)
      result = LivestreamScheduleGap.call
      assert_equal 1, result.size
      assert_equal "P2", result.first[:priority]
    end

    test "P1 when the gap exceeds the P1 threshold" do
      Livestream.create!(date: 18.days.ago.to_date)
      result = LivestreamScheduleGap.call
      assert_equal "P1", result.first[:priority]
    end

    test "no notification once the next livestream has already had had a next livestream scheduled" do
      Livestream.create!(date: 18.days.ago.to_date)
      CalendarEvent.create!(title: "下一場", event_type: "livestream", event_date: 2.days.from_now.to_date)
      assert_empty LivestreamScheduleGap.call
    end

    test "no notification during a livestream_pause exception range" do
      Livestream.create!(date: 18.days.ago.to_date)
      CalendarEvent.create!(title: "年假暫停", event_type: "livestream_pause",
                            event_date: 3.days.ago.to_date, end_date: 3.days.from_now.to_date)
      assert_empty LivestreamScheduleGap.call
    end

    test "a single-day pause only suppresses on that exact day" do
      Livestream.create!(date: 18.days.ago.to_date)
      CalendarEvent.create!(title: "單日暫停", event_type: "livestream_pause", event_date: 10.days.ago.to_date)
      assert_not_empty LivestreamScheduleGap.call, "a pause day 10 days ago must not suppress today's check"
    end

    test "no notifications at all when no livestream has ever happened" do
      assert_empty LivestreamScheduleGap.call
    end
  end
end
