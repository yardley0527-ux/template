# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingRunnerTest < ActiveSupport::TestCase
  setup do
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  teardown do
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "refreshes crm_customer_product_cycles when the cache is stale, fixing the root cause of the all-zero repurchase bug" do
    key = "runner_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "跑者測試品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%跑者測試品%'", regex_pattern: "跑者測試品(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 1, median_days: 30, source: "manual")

    # 用固定的週一日期而不是 Date.current，避免測試結果隨執行當天的星期幾漂移
    # （原本用 Date.current - 3 天，一週有5/7的機率會落到前一週，是不穩定的
    # 寫法）。
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))
    email = "repeat_#{SecureRandom.hex(4)}@example.com"
    ShoplineOrder.create!(order_number: "R1#{SecureRandom.hex(4)}", email: email, product_name: "跑者測試品1",
                          order_date: period.week_start - 60, payment_status: "已付款", quantity: 1, total_amount: 500)
    ShoplineOrder.create!(order_number: "R2#{SecureRandom.hex(4)}", email: email, product_name: "跑者測試品1",
                          order_date: period.week_start + 2, payment_status: "已付款", quantity: 1, total_amount: 500)

    # 手動插入一筆「過期很久」的 cycle 快照，模擬 crm_customer_product_cycles
    # 忘記排程刷新的情境——這正是「商品回購全部為0」的根因重現。
    CrmCustomerProductCycle.create!(
      identity_key: email, email: email, product_key: key,
      cycle_started_at: period.week_start - 60, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: period.week_start - 30, suggested_contact_date: period.week_start - 30,
      match_status: "not_yet_repurchased", refreshed_at: 10.days.ago
    )

    briefing, refresh_log = WeeklyBriefingRunner.call(week_start: period.week_start, force_refresh: false)

    assert_equal "refreshed (1 products)", refresh_log[:crm_customer_product_cycles]
    product_payload = briefing.metrics.dig("product_repurchase", "products")&.find { |p| p["product_key"] == key }
    assert product_payload, "expected the newly-refreshed product to appear in product_repurchase.products"
    assert_not product_payload["cycles_stale"], "cycles should no longer be considered stale after the runner refreshed them"
  end

  test "skips the expensive refresh when the cache is already fresh" do
    CustomerPurchaseSummary.create!(identity_key: "x", email: "x@example.com", first_date: Date.current,
                                     purchase_count: 1, silent_only: false, silent_days_threshold: 45)
    Livestream.create!(date: Date.current, stats_refreshed_at: Time.current)
    CrmCustomerProductCycle.create!(
      identity_key: "x@example.com", email: "x@example.com", product_key: "metabolism",
      cycle_started_at: Date.current - 30, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: Date.current, suggested_contact_date: Date.current,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )

    _briefing, refresh_log = WeeklyBriefingRunner.call(week_start: Date.current, force_refresh: false)

    assert_equal "skipped (fresh)", refresh_log[:customer_purchase_summaries]
    assert_equal "skipped (fresh)", refresh_log[:livestream_stats]
    assert_equal "skipped (fresh)", refresh_log[:crm_customer_product_cycles]
  end

  test "force_refresh always refreshes regardless of freshness" do
    CustomerPurchaseSummary.create!(identity_key: "x", email: "x@example.com", first_date: Date.current,
                                     purchase_count: 1, silent_only: false, silent_days_threshold: 45)

    _briefing, refresh_log = WeeklyBriefingRunner.call(week_start: Date.current, force_refresh: true)

    assert_equal "refreshed", refresh_log[:customer_purchase_summaries]
    assert_equal "refreshed", refresh_log[:livestream_stats]
  end
end
