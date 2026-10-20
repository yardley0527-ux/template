# frozen_string_literal: true

require "test_helper"

module Seo
  class BenchmarksTest < ActiveSupport::TestCase
    END_DATE = Date.new(2026, 10, 17)

    setup do
      # 前 4 週每天 100 點擊，本週每天 120
      (0..34).each do |i|
        SeoDailyMetric.create!(site: "yardley", date: END_DATE - i, clicks: i < 7 ? 120 : 100,
                               impressions: 5_000, ctr: 0.02, position: i < 7 ? 8.0 : 9.0)
      end
    end

    test "本週目標＝前 4 週週平均 × 1.05" do
      target = Benchmarks.new("yardley", END_DATE).weekly_target

      assert_equal 700, target[:base_clicks]
      assert_equal 735, target[:target_clicks]
      assert_equal 840, target[:clicks]
      assert target[:clicks_ok]
      assert target[:position_ok], "排名 8.0 比前 4 週 9.0 好"
    end

    test "沒有足夠資料的基準不顯示（去年同期不存在）" do
      labels = Benchmarks.new("yardley", END_DATE).baselines.map { |b| b[:label] }
      assert_includes labels, "近 90 天平均"
      refute_includes labels, "去年同期"
    end

    test "每日目標線用每一天自己的前 4 週" do
      by_date = (0..60).to_h { |i| [END_DATE - i, 100] }
      targets = Benchmarks.daily_targets(by_date, [END_DATE, END_DATE - 59])
      assert_equal [105, nil], targets
    end
  end
end
