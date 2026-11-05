# frozen_string_literal: true

require "test_helper"

module ReportCenter
  class ReportsTest < ActiveSupport::TestCase
    DAY = Date.new(2026, 10, 22)

    setup do
      ShoplineCustomer.create!(email: "old@example.com", full_name: "老客", membership_level: "金卡", instagram_account: "old_ig",
                               birthdate: Date.new(1985, 1, 1), line_id: "U1")
      ShoplineCustomer.create!(email: "alias@example.com", full_name: "分身", instagram_account: "@old_ig")
      ShoplineCustomer.create!(email: "new@example.com", full_name: "新客", membership_level: "一般會員", birthdate: Date.new(1995, 1, 1))
      ShoplineCustomer.create!(email: "back@example.com", full_name: "回來的")
      bad = ShoplineCustomer.create!(email: "bad@example.com", full_name: "黑名單")
      CustomerProfile.create!(shopline_customer: bad, blacklisted: true)

      order("#20260101040000001", "old@example.com", Date.new(2026, 1, 1), "全能5", 8000)
      # 21:30 台灣（13:30 UTC）：換 email 的舊客；主單含 A 單金額
      order("#20261022133000001", "alias@example.com", DAY, "PDRN10", 19_800, total: 25_000, payment: "銀行轉帳／ATM", city: "台北市")
      order("#20261022133000001A", "alias@example.com", DAY, "預購-全能5", 7990, total: nil, payment: "銀行轉帳／ATM")
      # 10:00 台灣（02:00 UTC）：新客，同一行重複匯入不重算，改名成「送」也是同一行
      order("#20261022020000002", "new@example.com", DAY, "PDRN10", 19_800, total: 22_450, payment: "中租 - zingala銀角零卡分期(6期)", city: "新北市")
      order("#20261022020000002", "new@example.com", DAY, "PDRN10送1", 19_800, total: nil, payment: "中租 - zingala銀角零卡分期(6期)")
      order("#20261022020000002", "new@example.com", DAY, "PDRN1", 2750, total: nil, payment: "中租 - zingala銀角零卡分期(6期)")
      # 買了又回來
      order("#20261010020000003", "back@example.com", Date.new(2026, 10, 10), "PDRN5", 21_000)
      order("#20261020020000004", "back@example.com", Date.new(2026, 10, 20), "代謝錠2", 5700)
      order("#20261012020000005", "bad@example.com", Date.new(2026, 10, 12), "PDRN10", 22_000)
    end

    test "同 IG 分身算舊客、A 單併主單不重複算金額、重複行只算一次" do
      data = Orders.new(DAY..DAY)
      assert_equal 2, data.all.size
      old = data.all.find { |o| o.email == "alias@example.com" }
      assert_not old.new_customer?
      assert_equal 25_000, old.amount
      assert_equal 2, old.lines.size

      fresh = data.all.find(&:new_customer?)
      assert_equal 22_450, fresh.amount
      assert_equal %w[PDRN10 PDRN1], fresh.lines.map(&:name).sort_by { |n| -n.size }
    end

    test "時段用訂單號碼換算台灣時間，新舊客分開" do
      data = Orders.new(DAY..DAY)
      assert_equal [10, 21], data.all.map(&:hour).sort
      text = Hours.new(data).parts.first.last
      assert_includes text, "10/22 業績時段分佈"
      assert_includes text, "新客 1 人、1 張單，$22,450"
      assert_includes text, "最高時段 20–24 點：1 張、$25,000"
    end

    test "區間內第一次買的人整段算新客；可只看某產品" do
      data = Orders.new(Date.new(2026, 10, 10)..DAY, product: "代謝錠")
      assert_equal ["back@example.com"], data.all.map(&:email)
      assert data.all.first.new_customer?
    end

    test "付款方式合併轉帳、中租分期數，分期比例" do
      parts = Payments.new(Orders.new(DAY..DAY)).parts
      assert_includes parts.first.last, "銀行轉帳 52.7%"
      assert_includes parts.first.last, "分期合計 47.3%"
      rows = parts.last[3].find { |b| b[0] == :table && b[1].first == "期數" }[2]
      assert_equal "6 期", rows.first.first
    end

    test "產品表按比例攤營收，組合比例分組數與數量" do
      parts = Products.new(Orders.new(DAY..DAY, product: "PDRN")).parts
      mix = parts.last[3].find { |b| b[0] == :table }[2]
      assert_equal [["PDRN", "1", 1, "33.3%", 1, "4.8%", 1], ["PDRN", "10", 2, "66.7%", 20, "95.2%", 1]], mix
    end

    test "客群輪廓有新舊客年齡與縣市" do
      parts = Profile.new(Orders.new(DAY..DAY)).parts
      tables = parts.last[3].select { |b| b[0] == :table }.map { |b| b[2] }
      assert_includes tables[0], ["30-39", 1, "100.0%", 0, "0.0%"]
      assert_includes tables[1], ["台北市", 0, "0.0%", 1, "100.0%"]
    end

    test "沒回來名單：買了又回來的不列、黑名單排除並寫出來" do
      list = Unrepurchased.new(product: "PDRN", range: Date.new(2026, 10, 1)..DAY, audience: "new", min_amount: 20_000, today: DAY + 1)
      assert_equal 3, list.buyers
      assert_equal 1, list.returned
      assert_equal ["新客"], list.entries.map(&:name)
      assert_equal ["黑名單"], list.excluded
      assert_includes list.parts.first.last, "已排除黑名單 1 人（黑名單）"
    end

    test "沒回來名單：全部買家含舊客，排除近 N 天、排除預購" do
      all = Unrepurchased.new(product: "全能", range: Date.new(2026, 10, 1)..DAY, audience: "all", today: DAY + 1)
      assert_equal ["分身"], all.entries.map(&:name) # 舊客也會列出（用下單那個 email 的名字）
      assert_equal 1, all.entries.size

      assert_empty Unrepurchased.new(product: "全能", range: Date.new(2026, 10, 1)..DAY, audience: "all", exclude_preorder: true, today: DAY + 1).entries
      assert_empty Unrepurchased.new(product: "PDRN", range: Date.new(2026, 10, 1)..DAY, skip_days: 30, today: DAY + 1).entries
    end

    private

    def order(number, email, date, name, price, total: price, payment: "信用卡付款", city: nil)
      ShoplineOrder.create!(order_number: number, email: email, product_name: name, quantity: 1, total_amount: total, checkout_amount: price,
                            payment_status: "已付款", payment_method: payment, city: city, order_date: date.in_time_zone.change(hour: 12))
    end
  end
end
