# frozen_string_literal: true

require "test_helper"

# 真實跨連線併發測試：LivestreamStatsRefreshService 的 session 級 blocking
# advisory lock。必須關閉 transactional fixtures——另一條真實連線（模擬另一個
# process/session）在 Postgres transaction isolation 下看不到本測試主執行緒
# 尚未 commit 的資料，因此改用手動建立/清除資料。
class LivestreamStatsRefreshServiceConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]
  DATE = Date.new(2034, 1, 1)
  ORDER_NUMBERS = %w[CONC_BEFORE CONC_AFTER_UNLOCK].freeze
  EMAIL = "concurrency-test@example.com"

  def taipei(h) = TAIPEI.local(DATE.year, DATE.month, DATE.day, h)

  setup do
    @livestream = Livestream.create!(date: DATE)
  end

  teardown do
    if @thread&.alive?
      @thread.kill
      @thread.join(2)
    end
    if @holder_conn
      begin
        @holder_conn.execute("SELECT pg_advisory_unlock_all()")
      rescue StandardError
        nil
      end
      begin
        ActiveRecord::Base.connection_pool.checkin(@holder_conn)
      rescue StandardError
        nil
      end
    end
    ShoplineOrder.where(order_number: ORDER_NUMBERS).delete_all
    ShoplineCustomer.where(email: EMAIL).delete_all
    Livestream.where(date: DATE).delete_all
    SyncRun.where(source: "livestream_stats").where("created_at > ?", 5.minutes.ago).delete_all
  end

  test "second refresh blocks while first holds the lock, then runs a fresh full computation after release" do
    ShoplineOrder.create!(order_number: "CONC_BEFORE", email: EMAIL, order_date: taipei(10),
                          total_amount: 100, product_name: "測試品")

    # pg_advisory_lock 回傳 SQL void（阻塞直到取得），沒有可斷言的布林值；
    # 這裡呼叫本身不拋例外、且立刻返回（此時無人持有鎖）就是成功的證明。
    @holder_conn = ActiveRecord::Base.connection_pool.checkout
    @holder_conn.execute("SELECT pg_advisory_lock(#{LivestreamStatsRefreshService::LOCK_ID})")

    result_holder = {}
    @thread = Thread.new do
      result_holder[:run] = LivestreamStatsRefreshService.call(date: DATE)
    end

    # 給背景執行緒足夠時間嘗試取鎖（此時應該被卡住，進不了計算區）
    sleep 0.4
    assert @thread.alive?, "鎖被持有時，第二個刷新應該還在等待，不該已經跑完"
    @livestream.reload
    assert_nil @livestream.stats_refreshed_at, "鎖被持有時，第二個刷新不該已經寫入任何統計"

    # 在鎖仍被持有時新增一筆訂單，驗證解鎖後第二個刷新是「重新完整計算」，
    # 不是用鎖等待前就已經算好的舊快照。
    ShoplineOrder.create!(order_number: "CONC_AFTER_UNLOCK", email: EMAIL, order_date: taipei(11),
                          total_amount: 50, product_name: "測試品")

    @holder_conn.execute("SELECT pg_advisory_unlock(#{LivestreamStatsRefreshService::LOCK_ID})")
    ActiveRecord::Base.connection_pool.checkin(@holder_conn)
    @holder_conn = nil

    joined = @thread.join(5)
    assert joined, "第二個刷新應在鎖釋放後的合理時間內完成（沒有 deadlock）"

    @livestream.reload
    assert_equal 2, @livestream.total_orders, "應反映解鎖後才新增的訂單，證明是重新完整計算"
    assert_equal 150.to_d, @livestream.total_revenue
    assert_kind_of SyncRun, result_holder[:run]
    assert_equal "success", result_holder[:run].status
  end

  test "ensure releases the lock even when the run raises before any per-event work" do
    original_create = SyncRun.method(:create!)
    SyncRun.define_singleton_method(:create!) do |**kwargs|
      raise "boom before per-event loop" if kwargs[:source] == "livestream_stats" && kwargs[:status] == "running"

      original_create.call(**kwargs)
    end

    begin
      assert_raises(RuntimeError) { LivestreamStatsRefreshService.call(date: DATE) }
    ensure
      SyncRun.define_singleton_method(:create!, original_create)
    end

    # 鎖必須已經釋放：立刻再呼叫一次不會卡住，且能正常完成
    completed = false
    t = Thread.new do
      LivestreamStatsRefreshService.call(date: DATE)
      completed = true
    end
    joined = t.join(3)
    assert joined, "例外後鎖若沒釋放，下一次呼叫會卡住"
    assert completed
  end
end
