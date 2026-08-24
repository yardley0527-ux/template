# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class LivestreamPerformanceDropTest < ActiveSupport::TestCase
    def order(email:, order_date:, amount:, product: "膠原蛋白6")
      ShoplineOrder.create!(product_name: product, email: email, order_date: order_date,
                            checkout_amount: amount, order_number: SecureRandom.hex(6))
    end

    def fresh_import!
      ImportRun.create!(kind: "paid_orders_workbook", file_name: "f.xlsx", file_checksum: SecureRandom.hex(8),
                        finished_at: Time.current)
    end

    # 3 個「前3場」，每場 D+1 window（livestream.date..date+1）都有固定營收。
    # 用很久以前的日期起算，避免這些「前場」自己又落在 target 的 30 天回看窗內
    # 被規則當成另一個 target 重新評估、污染 find 出來的結果。
    def seed_prior_livestreams(before_date:, revenue_per_livestream: 40_000, orders_per: 6)
      3.times do |i|
        ls_date = before_date - (10 * (i + 1))
        Livestream.create!(date: ls_date)
        orders_per.times { |j| order(email: "prior#{i}_#{j}@example.com", order_date: ls_date, amount: revenue_per_livestream / orders_per) }
      end
    end

    def result_for(target, offset)
      LivestreamPerformanceDrop.call.find { |r| r[:subject_id] == target.id.to_s && r[:metadata][:offset] == offset }
    end

    test "no card before D+1" do
      Livestream.create!(date: Date.current)
      assert_empty LivestreamPerformanceDrop.call
    end

    test "insufficient-data card (not P1) when fewer than the minimum comparable livestreams exist" do
      Livestream.create!(date: 40.days.ago.to_date) # only 1 comparable, below COMPARISON_MIN_COUNT (2)
      target = Livestream.create!(date: 1.day.ago.to_date)
      order(email: "a@example.com", order_date: target.date, amount: 1000)

      result = result_for(target, 1)
      assert result.present?
      assert_equal "P3", result[:priority]
      assert_equal false, result[:metadata][:data_sufficient]
    end

    test "no card when revenue is not meaningfully below the comparison baseline" do
      seed_prior_livestreams(before_date: 40.days.ago.to_date)
      target = Livestream.create!(date: 1.day.ago.to_date)
      6.times { |j| order(email: "t#{j}@example.com", order_date: target.date, amount: 40_000 / 6) }

      assert_nil result_for(target, 1)
    end

    test "P1 for a severe drop with sufficient baseline, absolute gap, and no confidence-lowering causes" do
      seed_prior_livestreams(before_date: 40.days.ago.to_date, revenue_per_livestream: 100_000)
      fresh_import!
      target = Livestream.create!(date: 3.days.ago.to_date)
      order(email: "t1@example.com", order_date: target.date, amount: 20_000) # 80% below baseline

      result = result_for(target, 1)
      assert_equal "P1", result[:priority]
      assert_empty result[:metadata][:possible_causes]
    end

    test "confidence is lowered (and priority downgraded) when the featured product is out of stock" do
      seed_prior_livestreams(before_date: 40.days.ago.to_date, revenue_per_livestream: 100_000)
      fresh_import!
      CrmProduct.create!(key: "collagen", label: "膠原蛋白", status: "confirmed", availability_status: "out_of_stock")
      target = Livestream.create!(date: 3.days.ago.to_date, product_keys: ["collagen"])
      order(email: "t1@example.com", order_date: target.date, amount: 20_000)

      result = result_for(target, 1)
      assert_not_equal "P1", result[:priority], "a severe drop with a plausible cause must not be asserted as P1"
      assert_includes result[:metadata][:possible_causes].join, "缺貨"
    end

    test "D+1 and D+3 are distinct cards with stable dedup_keys once both offsets are reached" do
      seed_prior_livestreams(before_date: 40.days.ago.to_date, revenue_per_livestream: 100_000)
      fresh_import!
      target = Livestream.create!(date: 3.days.ago.to_date)
      order(email: "t1@example.com", order_date: target.date, amount: 20_000)

      keys = LivestreamPerformanceDrop.call.select { |r| r[:subject_id] == target.id.to_s }.map { |r| r[:deduplication_key] }
      assert_includes keys, "livestream_performance_drop_d1:livestream:#{target.id}"
      assert_includes keys, "livestream_performance_drop_d3:livestream:#{target.id}"
    end

    test "livestreams older than the retention window are no longer evaluated" do
      target = Livestream.create!(date: 40.days.ago.to_date)
      order(email: "t1@example.com", order_date: target.date, amount: 1000)

      assert_empty LivestreamPerformanceDrop.call.select { |r| r[:subject_id] == target.id.to_s }
    end
  end
end
