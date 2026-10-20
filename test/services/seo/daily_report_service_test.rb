# frozen_string_literal: true

require "test_helper"

module Seo
  class DailyReportServiceTest < ActiveSupport::TestCase
    class FakeSearchConsole
      def sync_daily!(**)
        (0..13).each do |i|
          date = Date.new(2026, 10, 17) - i
          SeoDailyMetric.create!(site: "yardley", date: date, clicks: i < 7 ? 50 : 100, impressions: 1000, ctr: 0.05, position: 8.0)
        end
      end

      def latest_date(site) = site == "yardley" ? Date.new(2026, 10, 17) : nil
      def movers(*, **) = { "queries" => { "drops" => [], "gains" => [] }, "pages" => { "drops" => [], "gains" => [] } }
    end

    class BrokenHealthCheck
      def call(_site) = raise("boom")
    end

    class OkHealthCheck
      def call(_site) = [{ "check" => "ssl", "label" => "SSL", "url" => "u", "level" => "ok", "detail" => nil }]
    end

    test "產生摘要並記 SyncRun" do
      report = DailyReportService.call(date: Date.new(2026, 10, 20), search_console: FakeSearchConsole.new, health_check: OkHealthCheck.new)

      assert_equal "success", report.status
      summary = report.site_data("yardley")["summary"]
      assert_equal 350, summary["clicks"]
      assert_equal 700, summary.dig("previous", "clicks")
      assert_equal(-50.0, summary["clicks_change_pct"])
      assert_equal "success", SyncRun.latest_for("seo_daily").status
    end

    test "健康檢查壞掉時 GSC 部分照樣寫入，狀態 partial" do
      report = DailyReportService.call(date: Date.new(2026, 10, 20), search_console: FakeSearchConsole.new, health_check: BrokenHealthCheck.new)

      assert_equal "partial", report.status
      assert report.site_data("yardley")["summary"].present?
      assert_match "boom", report.error_message
    end
  end
end
