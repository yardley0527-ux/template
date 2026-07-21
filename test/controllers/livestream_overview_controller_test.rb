# frozen_string_literal: true

require "test_helper"

class LivestreamOverviewControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "admin-ov@test.com", username: "admin_ov", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "shows next scheduled livestream from calendar_events" do
    CalendarEvent.create!(title: "品牌之夜：測試", event_type: "livestream", event_date: Date.current + 5)
    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, (Date.current + 5).strftime("%Y/%m/%d")
  end

  test "clear empty state when there is no future scheduled livestream" do
    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, "尚無已排定的下一場直播"
  end

  test "shows latest completed event KPI and comparison against the previous one" do
    Livestream.create!(date: Date.current - 30, window_days: 3, stats_refreshed_at: Time.current,
                       total_orders: 100, total_revenue: 100_000, total_buyers: 100, new_buyers: 10)
    latest = Livestream.create!(date: Date.current - 10, window_days: 3, stats_refreshed_at: Time.current,
                                total_orders: 150, total_revenue: 150_000, total_buyers: 120, new_buyers: 30)

    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, latest.date.strftime("%Y/%m/%d")
    assert_includes @response.body, "較前一場"
  end

  test "no comparison text when there is no previous event" do
    Livestream.create!(date: Date.current - 5, window_days: 3, stats_refreshed_at: Time.current,
                       total_orders: 10, total_revenue: 10_000, total_buyers: 10, new_buyers: 1)
    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, "無前一場可比較"
  end

  test "shows warning banner when the latest livestream_stats SyncRun failed" do
    SyncRun.create!(source: "livestream_stats", status: "failed", started_at: Time.current, finished_at: Time.current,
                    error_messages: ["2040-01-01: RuntimeError — 統計刷新失敗，詳情見 server log"])
    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, "刷新失敗"
  end

  test "shows warning banner when the latest livestream_stats SyncRun is partial" do
    SyncRun.create!(source: "livestream_stats", status: "partial", started_at: Time.current, finished_at: Time.current)
    get livestream_overview_path
    assert_includes @response.body, "部分失敗"
  end

  test "no warning banner when the latest SyncRun succeeded" do
    SyncRun.create!(source: "livestream_stats", status: "success", started_at: Time.current, finished_at: Time.current)
    get livestream_overview_path
    assert_not_includes @response.body, "alert-danger"
  end

  test "does not trigger any stats refresh on page load" do
    Livestream.create!(date: Date.current - 5, window_days: 3)
    assert_no_difference "SyncRun.where(source: 'livestream_stats').count" do
      get livestream_overview_path
    end
  end

  test "links to livestreams index and to the existing crm broadcast page" do
    get livestream_overview_path
    assert_includes @response.body, livestreams_path
    assert_includes @response.body, crm_broadcast_path
  end

  # ── 補強：最新完成場次不得把窗口未結束的場次當成已定版 ─────────────────

  test "latest event still within its attribution window is clearly marked 未定版, not silently treated as final" do
    within_window = Livestream.create!(date: Date.current - 1, window_days: 3, stats_refreshed_at: Time.current,
                                       total_orders: 5, total_revenue: 5_000, total_buyers: 5, new_buyers: 1)
    get livestream_overview_path
    assert_response :success
    assert_includes @response.body, within_window.date.strftime("%Y/%m/%d")
    assert_includes @response.body, "數據未定版"
  end

  test "latest event past its window is not marked 未定版" do
    Livestream.create!(date: Date.current - 30, window_days: 3, stats_refreshed_at: Time.current,
                       total_orders: 5, total_revenue: 5_000, total_buyers: 5, new_buyers: 1)
    get livestream_overview_path
    assert_not_includes @response.body, "數據未定版"
  end

  # ── 補強：前一場營收為 0 時不得除以 0 ────────────────────────────────────

  test "percentage comparison does not divide by zero when the previous event had zero revenue/orders/buyers" do
    Livestream.create!(date: Date.current - 30, window_days: 3, stats_refreshed_at: Time.current,
                       total_orders: 0, total_revenue: 0, total_buyers: 0, new_buyers: 0)
    Livestream.create!(date: Date.current - 10, window_days: 3, stats_refreshed_at: Time.current,
                       total_orders: 50, total_revenue: 50_000, total_buyers: 40, new_buyers: 5)

    assert_nothing_raised do
      get livestream_overview_path
    end
    assert_response :success
    assert_includes @response.body, "無前一場可比較"
  end

  # ── 補強：latest SyncRun 查詢確實只看 livestream_stats 來源 ─────────────

  test "sync run status banner ignores SyncRun rows from other sources" do
    SyncRun.create!(source: "livestream_backfill", status: "failed", started_at: Time.current, finished_at: Time.current)
    SyncRun.create!(source: "livestream_stats", status: "success", started_at: Time.current, finished_at: Time.current)

    get livestream_overview_path
    assert_response :success
    assert_not_includes @response.body, "alert-danger"
  end
end
