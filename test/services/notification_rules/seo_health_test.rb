# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class SeoHealthTest < ActiveSupport::TestCase
    def check(check, level, url: "https://www.yardley.tw/", detail: "x")
      { "check" => check, "label" => check, "url" => url, "level" => level, "detail" => detail }
    end

    def report(checks: [], summary: nil, date: Date.current)
      SeoReport.create!(report_date: date, status: "success",
                        data: { "sites" => { "yardley" => { "checks" => checks, "summary" => summary, "data_through" => "2026-10-17" } } })
    end

    test "只推 critical/warning，同站同項目合併成一張卡" do
      report(checks: [check("noindex", "critical"), check("meta_description", "warning", url: "https://www.yardley.tw/products/a"),
                      check("meta_description", "warning", url: "https://www.yardley.tw/products/b"),
                      check("image_alt", "info"), check("ssl", "ok")])
      results = SeoHealth.call

      assert_equal 2, results.size
      noindex = results.find { |r| r[:subject_id] == "yardley:noindex" }
      assert_equal %w[critical P0], [noindex[:severity], noindex[:priority]]
      desc = results.find { |r| r[:subject_id] == "yardley:meta_description" }
      assert_equal 2, desc[:metadata][:urls].size
    end

    test "點擊比前週掉超過 30% 才推，前週太少不推" do
      report(summary: { "clicks" => 600, "clicks_change_pct" => -40.0, "previous" => { "clicks" => 1000 } })
      assert_equal ["seo_traffic_drop"], SeoHealth.call.map { |r| r[:notification_key] }

      SeoReport.delete_all
      report(summary: { "clicks" => 30, "clicks_change_pct" => -50.0, "previous" => { "clicks" => 60 } })
      assert_empty SeoHealth.call
    end

    test "報告太舊就不推" do
      report(checks: [check("noindex", "critical")], date: Date.current - 5)
      assert_empty SeoHealth.call
    end
  end
end
