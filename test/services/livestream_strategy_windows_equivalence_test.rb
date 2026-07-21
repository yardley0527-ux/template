# frozen_string_literal: true

require "test_helper"

# 方案 B PR4 效能修正：LivestreamStrategyController.batch_window_comparisons
# 把「45 場 × 4 窗口 = 180 次個別 LivestreamAttribution 查詢」改成整頁只掃描
# 一次，在記憶體中依場次/窗口切分。換算法不能換出不一樣的數字——這裡逐場
# 逐窗口比對批次版本與 PR2 既有 LivestreamAttribution.window_comparison
# （逐一呼叫、查詢量大但正確性已由 PR2 驗證過）的輸出完全一致。
class LivestreamStrategyWindowsEquivalenceTest < ActiveSupport::TestCase
  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]

  def taipei(y, m, d, h = 10) = TAIPEI.local(y, m, d, h)

  def order!(order_number:, email:, order_date:, total_amount:, checkout_amount: nil)
    ShoplineOrder.create!(order_number: order_number, email: email, order_date: order_date,
                          total_amount: total_amount, checkout_amount: checkout_amount, product_name: "測試品")
  end

  test "batch computation matches per-event LivestreamAttribution.window_comparison exactly" do
    # 3 場，場距故意設計成有的近（會在寬窗重疊）、有的遠，涵蓋典型情境。
    ls1 = Livestream.create!(date: Date.new(2050, 1, 1), window_days: 3)
    ls2 = Livestream.create!(date: Date.new(2050, 1, 5), window_days: 3) # 與 ls1 相距 4 天
    ls3 = Livestream.create!(date: Date.new(2050, 2, 1), window_days: 3) # 與 ls2 相距很遠

    # 一般訂單
    order!(order_number: "W1", email: "a@x.com", order_date: taipei(2050, 1, 1), total_amount: 500)
    order!(order_number: "W2", email: "b@x.com", order_date: taipei(2050, 1, 2), total_amount: 300)
    # 落在 ls1 與 ls2 窗口交集的訂單（+7 窗會重疊，+3 窗依日期可能只落一邊）
    order!(order_number: "W3", email: "c@x.com", order_date: taipei(2050, 1, 5), total_amount: 700)
    # 舊客（history）＋新客
    order!(order_number: "W4-hist", email: "d@x.com", order_date: taipei(2049, 6, 1), total_amount: 100)
    order!(order_number: "W4", email: "d@x.com", order_date: taipei(2050, 1, 1), total_amount: 200)
    order!(order_number: "W5", email: "new@x.com", order_date: taipei(2050, 1, 1), total_amount: 900)
    # NULL email（未識別）
    order!(order_number: "W6", email: nil, order_date: taipei(2050, 1, 1), total_amount: 150)
    # total_amount 全為 0，fallback checkout_amount
    order!(order_number: "W7", email: "e@x.com", order_date: taipei(2050, 1, 2), total_amount: 0, checkout_amount: 250)
    # 遠場次
    order!(order_number: "W8", email: "f@x.com", order_date: taipei(2050, 2, 1), total_amount: 400)

    events = [ls1, ls2, ls3]
    batch = LivestreamStrategyController.batch_window_comparisons(events)

    events.each do |ls|
      expected = LivestreamAttribution.window_comparison(ls)
      actual = batch.find { |b| b[:livestream].id == ls.id }[:comparison]

      expected.each do |exp_row|
        act_row = actual.find { |r| r[:window_days] == exp_row[:window_days] }
        assert_equal exp_row[:orders], act_row[:orders], "#{ls.date} D+#{exp_row[:window_days]} orders 不一致"
        assert_equal exp_row[:revenue], act_row[:revenue], "#{ls.date} D+#{exp_row[:window_days]} revenue 不一致"
        assert_equal exp_row[:buyers], act_row[:buyers], "#{ls.date} D+#{exp_row[:window_days]} buyers 不一致"
        assert_equal exp_row[:new_buyers], act_row[:new_buyers], "#{ls.date} D+#{exp_row[:window_days]} new_buyers 不一致"
        assert_equal exp_row[:unidentified_orders], act_row[:unidentified_orders], "#{ls.date} D+#{exp_row[:window_days]} unidentified_orders 不一致"
      end
    end
  end

  test "batch computation issues a constant number of queries regardless of event count" do
    5.times { |i| Livestream.create!(date: Date.new(2051, 1, 1) + (i * 10), window_days: 3) }
    events = Livestream.where(date: Date.new(2051, 1, 1)..Date.new(2051, 12, 31)).order(:date).to_a

    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:sql] =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      LivestreamStrategyController.batch_window_comparisons(events)
    end

    assert_operator count, :<=, 3, "批次版本應該是常數級查詢數（撈訂單 1 條＋首購日 1 條），不隨場次數線性增加：實際 #{count}"
  end

  test "batch computation returns empty array for no events without querying" do
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:sql] =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/ }
    result = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      result = LivestreamStrategyController.batch_window_comparisons([])
    end
    assert_equal [], result
    assert_equal 0, count
  end
end
