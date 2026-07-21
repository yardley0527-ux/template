# frozen_string_literal: true

require "test_helper"

class SyncRunTest < ActiveSupport::TestCase
  test "rejects unknown source and status" do
    assert_not SyncRun.new(source: "nonsense", status: "success", started_at: Time.current).valid?
    assert_not SyncRun.new(source: "department_sheets", status: "weird", started_at: Time.current).valid?
  end

  test "last_finished_at only counts success and partial runs" do
    SyncRun.create!(source: "department_sheets", status: "failed",
                    started_at: 3.hours.ago, finished_at: 3.hours.ago)
    ok = SyncRun.create!(source: "department_sheets", status: "success",
                         started_at: 2.hours.ago, finished_at: 2.hours.ago)

    assert_in_delta ok.finished_at.to_f, SyncRun.last_finished_at("department_sheets").to_f, 1
  end

  test "current_alerts empty when all sources healthy" do
    SyncRun.create!(source: "department_sheets", status: "success",
                    started_at: Time.current, finished_at: Time.current)
    SyncRun.create!(source: "annual_calendar", status: "success",
                    started_at: Time.current, finished_at: Time.current)

    assert_empty SyncRun.current_alerts
  end

  test "current_alerts names failed departments on partial run" do
    SyncRun.create!(
      source: "department_sheets", status: "partial",
      started_at: Time.current, finished_at: Time.current,
      meta: { "物流部" => { "dates" => 8, "error" => nil },
              "廣告部" => { "dates" => 0, "error" => "OpenURI::HTTPError: 403" } }
    )

    alerts = SyncRun.current_alerts
    assert_equal 1, alerts.size
    assert_includes alerts.first, "部門日誌"
    assert_includes alerts.first, "廣告部"
    assert_not_includes alerts.first, "物流部"
  end

  test "current_alerts reports failed annual calendar sync" do
    SyncRun.create!(source: "annual_calendar", status: "failed",
                    started_at: Time.current, finished_at: Time.current,
                    error_messages: ["找不到 26總表 分頁"])

    assert(SyncRun.current_alerts.any? { |a| a.include?("年度行事曆同步失敗") })
  end

  test "only the latest run per source counts" do
    SyncRun.create!(source: "annual_calendar", status: "failed",
                    started_at: 2.hours.ago, finished_at: 2.hours.ago)
    SyncRun.create!(source: "annual_calendar", status: "success",
                    started_at: 1.hour.ago, finished_at: 1.hour.ago)

    assert_empty SyncRun.current_alerts
  end

  test "accepts crm_rollup as a source" do
    assert SyncRun.new(source: "crm_rollup", status: "running", started_at: Time.current).valid?
  end

  test "current_alerts stays quiet when crm_rollup has never run" do
    assert_empty SyncRun.current_alerts
  end

  test "current_alerts flags crm_rollup staleness after 26 hours" do
    SyncRun.create!(source: "crm_rollup", status: "success",
                    started_at: 30.hours.ago, finished_at: 30.hours.ago)

    assert(SyncRun.current_alerts.any? { |a| a.include?("CRM 旅程快取") && a.include?("未更新") })
  end

  test "current_alerts quiet for a fresh successful crm_rollup" do
    SyncRun.create!(source: "crm_rollup", status: "success",
                    started_at: 2.hours.ago, finished_at: 2.hours.ago)

    assert_empty SyncRun.current_alerts
  end

  test "current_alerts reports failed crm_rollup with product detail" do
    SyncRun.create!(
      source: "crm_rollup", status: "partial",
      started_at: 1.hour.ago, finished_at: 1.hour.ago,
      meta: { "omnipotent" => { "tracking_rows" => 10, "error" => nil },
              "turmeric"   => { "tracking_rows" => nil, "error" => "PG::ConnectionBad" } }
    )

    alert = SyncRun.current_alerts.find { |a| a.include?("CRM 旅程快取") }
    assert alert
    assert_includes alert, "turmeric"
  end
end
