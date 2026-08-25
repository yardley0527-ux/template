# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class SystemHealthTest < ActiveSupport::TestCase
    def fresh_import_run(kind)
      ImportRun.create!(kind: kind, file_name: "f.xlsx", file_checksum: SecureRandom.hex(8),
                         started_at: 2.hours.ago, finished_at: 1.hour.ago)
    end

    def quiet_baseline
      fresh_import_run("paid_orders_workbook")
      fresh_import_run("customers_report")
    end

    test "a kind that has never completed an import is flagged critical, never-run message" do
      fresh_import_run("customers_report")

      result = SystemHealth.call.find { |r| r[:subject_id] == "paid_orders_workbook" }
      assert result.present?
      assert_equal "critical", result[:severity]
      assert_includes result[:message], "從未成功完成過"
    end

    test "an import finished within 36 hours does not trigger staleness" do
      quiet_baseline
      assert_empty SystemHealth.call.select { |r| r[:subject_type] == "import_kind" }
    end

    test "an import finished more than 36 hours ago triggers critical staleness with an hour count" do
      fresh_import_run("customers_report")
      ImportRun.create!(kind: "paid_orders_workbook", file_name: "f.xlsx", file_checksum: SecureRandom.hex(8),
                         started_at: 40.hours.ago, finished_at: 40.hours.ago)

      result = SystemHealth.call.find { |r| r[:subject_id] == "paid_orders_workbook" }
      assert_equal "critical", result[:severity]
      assert_includes result[:message], "40 小時前"
    end

    test "a crm_rollup source that has never run does not alert (only genuinely-stale runs do)" do
      quiet_baseline
      assert_empty SystemHealth.call.select { |r| r[:subject_id] == "crm_rollup" }
    end

    test "a crm_rollup last success more than 26 hours ago triggers critical staleness" do
      quiet_baseline
      SyncRun.create!(source: "crm_rollup", status: "success", started_at: 30.hours.ago, finished_at: 30.hours.ago)

      result = SystemHealth.call.find { |r| r[:subject_id] == "crm_rollup" }
      assert result.present?
      assert_equal "critical", result[:severity]
    end

    test "a crm_rollup success within 26 hours does not alert" do
      quiet_baseline
      SyncRun.create!(source: "crm_rollup", status: "success", started_at: 1.hour.ago, finished_at: 1.hour.ago)

      assert_empty SystemHealth.call.select { |r| r[:subject_id] == "crm_rollup" }
    end

    test "a non-crm_rollup sync source with the latest run failed is flagged warning" do
      quiet_baseline
      SyncRun.create!(source: "dandy_inventory", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago)

      result = SystemHealth.call.find { |r| r[:subject_id] == "dandy_inventory" }
      assert result.present?
      assert_equal "warning", result[:severity]
    end

    test "a sync source whose latest run succeeded after an earlier failure is not flagged" do
      quiet_baseline
      SyncRun.create!(source: "dandy_inventory", status: "failed", started_at: 2.hours.ago, finished_at: 2.hours.ago)
      SyncRun.create!(source: "dandy_inventory", status: "success", started_at: 1.hour.ago, finished_at: 1.hour.ago)

      assert_empty SystemHealth.call.select { |r| r[:subject_id] == "dandy_inventory" }
    end

    test "a failed DailyBriefing is flagged" do
      quiet_baseline
      DailyBriefing.create!(briefing_date: Date.current, status: "failed", error_message: "boom")

      result = SystemHealth.call.find { |r| r[:subject_type] == "daily_briefing" }
      assert result.present?
      assert_equal "warning", result[:severity]
    end

    test "a successful DailyBriefing does not alert" do
      quiet_baseline
      DailyBriefing.create!(briefing_date: Date.current, status: "success")

      assert_empty SystemHealth.call.select { |r| r[:subject_type] == "daily_briefing" }
    end

    test "briefing_failure metadata only stores the date, not the free-text error message" do
      quiet_baseline
      DailyBriefing.create!(briefing_date: Date.current, status: "failed", error_message: "OpenAI timeout")

      result = SystemHealth.call.find { |r| r[:subject_type] == "daily_briefing" }
      assert_not_includes result[:metadata].to_s, "OpenAI timeout"
      assert_equal [:briefing_date], result[:metadata].keys
    end
  end
end
