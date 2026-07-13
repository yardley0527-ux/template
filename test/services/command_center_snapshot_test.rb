# frozen_string_literal: true

require "test_helper"

class CommandCenterSnapshotTest < ActiveSupport::TestCase
  setup { travel_to Time.zone.local(2026, 7, 13, 8, 0, 0) }
  teardown { travel_back }

  test "picks the nearest future livestream and arrival" do
    CalendarEvent.create!(title: "過去的直播", event_type: "livestream", event_date: Date.new(2026, 7, 1))
    near = CalendarEvent.create!(title: "品牌之夜：美白", event_type: "livestream", event_date: Date.new(2026, 7, 17))
    CalendarEvent.create!(title: "品牌之夜：膠原", event_type: "livestream", event_date: Date.new(2026, 7, 24))
    arrival = CalendarEvent.create!(title: "冰晶蕃茄到貨", event_type: "arrival", event_date: Date.new(2026, 7, 21))

    snapshot = CommandCenterSnapshot.call

    assert_equal near, snapshot[:next_livestream]
    assert_equal arrival, snapshot[:next_arrival]
  end

  test "today's event still counts as upcoming" do
    today_event = CalendarEvent.create!(title: "今天直播", event_type: "livestream", event_date: Date.current)

    assert_equal today_event, CommandCenterSnapshot.call[:next_livestream]
  end

  test "handles empty calendar gracefully" do
    snapshot = CommandCenterSnapshot.call

    assert_nil snapshot[:next_livestream]
    assert_nil snapshot[:next_arrival]
    assert_empty snapshot[:upcoming_events]
  end

  test "department lights reflect today's reports and last date" do
    DepartmentUpdate.create!(department: "物流部", log_date: Date.current, content: "出貨 10 筆")
    DepartmentUpdate.create!(department: "廣告部", log_date: Date.current - 2, content: "推播圖")

    lights = CommandCenterSnapshot.call[:department_lights].index_by { |l| l[:department] }

    assert lights["物流部"][:reported_today]
    assert_equal Date.current, lights["物流部"][:last_date]
    assert_not lights["廣告部"][:reported_today]
    assert_equal Date.current - 2, lights["廣告部"][:last_date]
    assert_not lights["CRM"][:reported_today]
    assert_nil lights["CRM"][:last_date]
    assert_equal DepartmentUpdate::DEPARTMENTS.size, lights.size
  end

  test "surfaces sync alerts" do
    SyncRun.create!(source: "annual_calendar", status: "failed",
                    started_at: Time.current, finished_at: Time.current)

    assert(CommandCenterSnapshot.call[:sync_alerts].any? { |a| a.include?("年度行事曆") })
  end
end
