# frozen_string_literal: true

require "test_helper"

class DepartmentSheetSyncTest < ActiveSupport::TestCase
  # 攔掉真正的 Google 下載：per-department 結果由 stub 決定
  class FakeSync < DepartmentSheetSync
    attr_writer :fake_results

    private

    def sync_department(department, _sheet_id)
      @fake_results.fetch(department, { dates: 1, error: nil })
    end
  end

  test "records a success SyncRun when every department syncs" do
    sync = FakeSync.new
    sync.fake_results = {}

    assert_difference -> { SyncRun.count }, 1 do
      sync.call
    end

    run = SyncRun.latest_for("department_sheets")
    assert_equal "success", run.status
    assert run.finished_at.present?
    assert_equal DepartmentSheetSync::SHEETS.size, run.meta.size
    assert_empty run.error_messages
  end

  test "records partial status and error detail when one department fails" do
    sync = FakeSync.new
    sync.fake_results = { "廣告部" => { dates: 0, error: "boom" } }
    sync.call

    run = SyncRun.latest_for("department_sheets")
    assert_equal "partial", run.status
    assert_equal ["廣告部"], run.failed_parts
    assert_includes run.error_messages.first, "廣告部"
  end

  test "records failed status when every department fails" do
    sync = FakeSync.new
    sync.fake_results = DepartmentSheetSync::SHEETS.keys.index_with { { dates: 0, error: "down" } }
    sync.call

    assert_equal "failed", SyncRun.latest_for("department_sheets").status
  end

  test "recent_sheets keeps only current and previous month tabs" do
    travel_to Date.new(2026, 7, 15) do
      assert_equal %w[6 7], DepartmentSheetSync.new.send(:recent_sheets, %w[1 2 3 4 5 6 7 12])
    end
  end

  test "recent_sheets spans the year boundary in January" do
    travel_to Date.new(2026, 1, 5) do
      assert_equal %w[12 1], DepartmentSheetSync.new.send(:recent_sheets, %w[10 11 12 1])
    end
  end

  test "recent_sheets falls back to all tabs when names are not month numbers" do
    tabs = %w[工作日誌 備註]
    assert_equal tabs, DepartmentSheetSync.new.send(:recent_sheets, tabs)
  end

  test "last_run_at falls back to durable SyncRun records" do
    DepartmentSheetSync.memory_last_run_at = nil
    Rails.cache.delete(DepartmentSheetSync::LAST_RUN_CACHE_KEY)
    SyncRun.create!(source: "department_sheets", status: "success",
                    started_at: 1.hour.ago, finished_at: 1.hour.ago)

    assert_in_delta 1.hour.ago.to_f, DepartmentSheetSync.last_run_at.to_f, 5
  end
end
