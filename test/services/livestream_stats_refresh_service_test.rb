# frozen_string_literal: true

require "test_helper"

class LivestreamStatsRefreshServiceTest < ActiveSupport::TestCase
  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]

  def taipei(y, m, d, h = 10) = TAIPEI.local(y, m, d, h)

  def livestream!(date, window_days: 3)
    Livestream.create!(date: date, window_days: window_days)
  end

  def order!(order_number:, email:, order_date:, total_amount:, membership_level: nil)
    customer = if email && membership_level
                 ShoplineCustomer.find_or_create_by!(email: email) { |c| c.membership_level = membership_level }
               end
    ShoplineOrder.create!(order_number: order_number, email: email, order_date: order_date,
                          total_amount: total_amount, product_name: "測試品",
                          shopline_customer_id: customer&.id)
  end

  test "refresh writes stats fields and creates success SyncRun" do
    ls = livestream!(Date.new(2031, 1, 1))
    order!(order_number: "O1", email: "a@x.com", order_date: taipei(2031, 1, 1), total_amount: 1000, membership_level: "黑卡")
    order!(order_number: "O2", email: "b@x.com", order_date: taipei(2031, 1, 2), total_amount: 500, membership_level: "金卡")

    run = LivestreamStatsRefreshService.call(date: ls.date)
    assert_instance_of SyncRun, run
    assert_equal "livestream_stats", run.source
    assert_equal "success", run.status
    assert_not_nil run.finished_at

    ls.reload
    assert_equal 2, ls.total_orders
    assert_equal 1500.to_d, ls.total_revenue
    assert_equal 2, ls.total_buyers
    assert_equal 1, ls.level_black_count
    assert_equal 1000.to_d, ls.level_black_amount
    assert_equal 1, ls.level_gold_count
    assert_equal 500.to_d, ls.level_gold_amount
    assert_equal 0, ls.level_silver_count
    assert_not_nil ls.stats_refreshed_at
  end

  test "refresh is idempotent across repeated calls" do
    ls = livestream!(Date.new(2031, 1, 1))
    order!(order_number: "O1", email: "a@x.com", order_date: taipei(2031, 1, 1), total_amount: 700, membership_level: "白卡")

    LivestreamStatsRefreshService.call(date: ls.date)
    first = ls.reload.attributes.slice("total_orders", "total_revenue", "total_buyers", "level_white_count", "level_white_amount")

    LivestreamStatsRefreshService.call(date: ls.date)
    second = ls.reload.attributes.slice("total_orders", "total_revenue", "total_buyers", "level_white_count", "level_white_amount")

    assert_equal first, second
  end

  test "full refresh with no DATE processes all livestreams" do
    livestream!(Date.new(2031, 2, 1))
    livestream!(Date.new(2031, 2, 5))

    run = LivestreamStatsRefreshService.call
    assert_equal "success", run.status
    assert_equal 2, run.meta["succeeded"]
    assert Livestream.where(date: [Date.new(2031, 2, 1), Date.new(2031, 2, 5)]).all? { |l| l.stats_refreshed_at.present? }
  end

  test "single event failure does not affect others; SyncRun reports partial with no customer PII in error_messages" do
    good = livestream!(Date.new(2031, 3, 1))
    bad  = livestream!(Date.new(2031, 3, 10))
    order!(order_number: "GOOD1", email: "a@x.com", order_date: taipei(2031, 3, 1), total_amount: 100)

    boom = ->(target) { raise "boom for #{target.date}" if target.id == bad.id }

    original_new = LivestreamAttribution.method(:new)
    LivestreamAttribution.define_singleton_method(:new) do |livestream, **kwargs|
      boom.call(livestream)
      original_new.call(livestream, **kwargs)
    end

    begin
      run = LivestreamStatsRefreshService.call
    ensure
      LivestreamAttribution.singleton_class.send(:remove_method, :new)
    end

    assert_equal "partial", run.status
    assert_equal 1, run.meta["failed"]
    assert good.reload.stats_refreshed_at.present?
    assert_nil bad.reload.stats_refreshed_at

    assert_equal 1, run.error_messages.size
    assert_match bad.date.iso8601, run.error_messages.first
    assert_no_match(/@/, run.error_messages.first) # 無 email 等個資
  end

  test "all events failing yields failed status" do
    livestream!(Date.new(2031, 4, 1))

    LivestreamAttribution.define_singleton_method(:new) { |*| raise "always boom" }
    begin
      run = LivestreamStatsRefreshService.call
    ensure
      LivestreamAttribution.singleton_class.send(:remove_method, :new)
    end

    assert_equal "failed", run.status
    assert_equal 0, run.meta["succeeded"]
    assert_equal 1, run.meta["failed"]
  end

  # 鎖行為改為 blocking（pg_advisory_lock），真實跨連線併發測試見
  # test/services/livestream_stats_refresh_service_concurrency_test.rb
  # （需要 use_transactional_tests = false 才能讓第二條連線看到第一條連線的資料，
  # 不適合和其他測試共用 transactional fixtures 的這個檔案）。
  test "lock is released after a run completes so a subsequent sequential call succeeds" do
    livestream!(Date.new(2031, 6, 1))
    first = LivestreamStatsRefreshService.call
    assert_kind_of SyncRun, first
    second = LivestreamStatsRefreshService.call
    assert_kind_of SyncRun, second
  end

  # ── 安全錯誤訊息（不得含 e.message 原文）───────────────────────────────

  test "error_messages never contain raw exception message, only date + exception class + fixed summary" do
    ls = livestream!(Date.new(2035, 1, 1))
    sensitive = "customer secret@example.com phone 0912-345-678 name 王小明 SQL bind leaked"

    LivestreamAttribution.define_singleton_method(:new) { |*| raise sensitive }
    begin
      run = LivestreamStatsRefreshService.call(date: ls.date)
    ensure
      LivestreamAttribution.singleton_class.send(:remove_method, :new)
    end

    joined = run.error_messages.join(" | ")
    assert_no_match(/@/, joined)
    assert_no_match(/secret@example\.com/, joined)
    assert_no_match(/0912-345-678/, joined)
    assert_no_match(/王小明/, joined)
    assert_no_match(/SQL bind leaked/, joined)
    assert_match "RuntimeError", joined
    assert_match ls.date.iso8601, joined
    assert_match LivestreamStatsRefreshService::SAFE_ERROR_SUFFIX, joined
  end

  # ── 卡別統計正確性 ───────────────────────────────────────────────────────

  test "level_*_count counts each email once even with multiple orders" do
    ls = livestream!(Date.new(2036, 1, 1))
    order!(order_number: "M1", email: "a@x.com", order_date: taipei(2036, 1, 1), total_amount: 300, membership_level: "黑卡")
    order!(order_number: "M2", email: "a@x.com", order_date: taipei(2036, 1, 2), total_amount: 200)

    LivestreamStatsRefreshService.call(date: ls.date)
    ls.reload
    assert_equal 1, ls.level_black_count
    assert_equal 500.to_d, ls.level_black_amount
  end

  test "same order_number split across lines is not double counted in level amount" do
    ls = livestream!(Date.new(2036, 2, 1))
    customer = ShoplineCustomer.create!(email: "dup@x.com", membership_level: "金卡")
    ShoplineOrder.create!(order_number: "SAME", email: "dup@x.com", order_date: taipei(2036, 2, 1),
                          total_amount: 800, checkout_amount: 500, product_name: "a", shopline_customer_id: customer.id)
    ShoplineOrder.create!(order_number: "SAME", email: "dup@x.com", order_date: taipei(2036, 2, 1),
                          total_amount: 800, checkout_amount: 300, product_name: "b", shopline_customer_id: customer.id)

    LivestreamStatsRefreshService.call(date: ls.date)
    ls.reload
    assert_equal 1, ls.level_gold_count
    assert_equal 800.to_d, ls.level_gold_amount # 單一訂單金額，不是兩個 line 相加
  end

  test "shopline_customers.email unique index makes duplicate-customer amplification structurally impossible" do
    # index_shopline_customers_on_email（db/schema.rb）是 partial unique index
    # （email IS NOT NULL 時唯一），DB 層面就不允許同一 email 出現兩筆客戶紀錄，
    # 所以 level_breakdown 的 Hash-based 查找（membership_by_email）不可能因
    # 重複客戶紀錄放大人數或金額——這裡直接證明該唯一索引存在且生效。
    ShoplineCustomer.create!(email: "unique-check@x.com", membership_level: "銀卡")
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO shopline_customers (email, membership_level, created_at, updated_at) " \
        "VALUES ('unique-check@x.com', '銀卡', now(), now())"
      )
    end
  end

  test "buyer with no matching ShoplineCustomer is excluded from every level, not counted as 一般會員" do
    ls = livestream!(Date.new(2036, 4, 1))
    order!(order_number: "U1", email: "unmatched@x.com", order_date: taipei(2036, 4, 1), total_amount: 250) # no customer created

    LivestreamStatsRefreshService.call(date: ls.date)
    ls.reload
    assert_equal 1, ls.total_buyers
    total_level_count = %i[level_black_count level_gold_count level_silver_count level_white_count level_normal_count]
                          .sum { |a| ls.public_send(a) }
    assert_equal 0, total_level_count
    assert_equal 0, ls.level_normal_count
    assert_equal 0.to_d, ls.level_normal_amount
  end

  test "sum of identified level amounts equals revenue when every buyer is identified and matched" do
    ls = livestream!(Date.new(2036, 5, 1))
    order!(order_number: "I1", email: "a@x.com", order_date: taipei(2036, 5, 1), total_amount: 300, membership_level: "黑卡")
    order!(order_number: "I2", email: "b@x.com", order_date: taipei(2036, 5, 1), total_amount: 700, membership_level: "一般會員")

    LivestreamStatsRefreshService.call(date: ls.date)
    ls.reload
    level_amount_sum = %i[level_black_amount level_gold_amount level_silver_amount level_white_amount level_normal_amount]
                         .sum { |a| ls.public_send(a) }
    assert_equal ls.total_revenue, level_amount_sum
  end
end
