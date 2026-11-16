# frozen_string_literal: true

require "test_helper"

module SalesDaily
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_texts(to, texts) = @sent << [to, texts]
    end

    DAY = Date.new(2026, 10, 3)

    setup do
      @old_token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"]
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
      LineBotGroup.create!(group_id: "Csales", name: "苼莛國際-銷售後台", subscriptions: ["sales_daily"])
      LineBotGroup.create!(group_id: "Cbrief", subscriptions: ["order_brief"])

      ShoplineCustomer.create!(email: "gold@example.com", full_name: "金卡客", membership_level: "金卡", birthdate: Date.new(1990, 5, 1))
      ShoplineCustomer.create!(email: "new@example.com", full_name: "新客", membership_level: "一般會員", birthdate: Date.new(1980, 5, 1))

      order("#G0", "gold@example.com", Date.new(2026, 9, 1), "全能3", 3, total: 9000, checkout: 9000)
      order("#G1", "gold@example.com", Date.new(2026, 10, 1), "全能12送1", 1, total: 160_000, checkout: 160_000)
      order("#G2", "gold@example.com", DAY, "PDRN1", 2, total: 6000, checkout: 5000)
      order("#G2", "gold@example.com", DAY, "全能2", 1, total: 6000, checkout: 1000)  # 同一張單第二行
      order("#N1", "new@example.com", DAY, "PDRN1", 1, total: nil, checkout: 2750)     # 整單金額空白→用 checkout
    end

    teardown { ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token }

    def order(number, email, date, product, quantity, total:, checkout:)
      ShoplineOrder.create!(order_number: number, email: email, product_name: product, quantity: quantity, total_amount: total,
                            checkout_amount: checkout, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day, 12))
    end

    test "前一天訂單、當月累計、卡別、年齡層、熱銷商品" do
      text = LineDigest.new(DAY, line: FakeLine.new).message

      assert_includes text, "📊 10/3（六） SL 訂單\n訂單 2 單｜營收 $8,750（均 $4,375）\n舊客 1人/1單 $6,000（均 $6,000）\n新客 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "📅 10 月累計（10/1–10/3）\n$168,750｜3 天中 1 天達標\n日均 $56,250（日目標 $150,000）\n舊客 $166,000｜新客 $2,750"
      assert_includes text, "金卡 1人/1單 $6,000（均 $6,000）\n銀卡 0 人"
      assert_includes text, "新客 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "30-39 1人/1單 $6,000（均 $6,000）\n40-49 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "1. PDRN1\n  3 個／2 單｜$7,750（88.6%）\n2. 全能2\n  1 個／1 單｜$1,000（11.4%）"
    end

    test "好幾天不加總：每一段都每天各一塊，網頁另有每天的直條圖資料" do
      order("#G3", "gold@example.com", Date.new(2026, 10, 4), "PDRN1", 1, total: 2750, checkout: 2750)
      digest = LineDigest.new(DAY..Date.new(2026, 10, 4), line: FakeLine.new)
      text = digest.message

      assert_includes text, "📊 10/3（六）–10/4（日） SL 訂單\n\n10/3（六） ❌\n訂單 2 單｜營收 $8,750（均 $4,375）\n舊客 1人/1單 $6,000（均 $6,000）\n新客 1人/1單 $2,750（均 $2,750）\n\n10/4（日） ❌\n訂單 1 單｜營收 $2,750（均 $2,750）\n舊客 1人/1單 $2,750"
      assert_not_includes text, "訂單 3 單" # 不加總
      assert_includes text, "📅 10 月累計（10/1–10/4）\n$171,500｜4 天中 1 天達標"
      assert_includes text, "👑 10/3–10/4 購買卡別\n\n10/3（六）\n黑卡 0 人\n金卡 1人/1單 $6,000"
      assert_includes text, "10/4（日）\n黑卡 0 人\n金卡 1人/1單 $2,750"
      assert_includes text, "🎂 10/3–10/4 年齡層\n\n10/3（六）\n30-39 1人/1單 $6,000（均 $6,000）\n40-49 1人/1單 $2,750（均 $2,750）\n\n10/4（日）\n30-39 1人/1單 $2,750"
      assert_includes text, "🔥 10/3–10/4 熱銷商品\n\n10/3（六）\n1. PDRN1\n  3 個／2 單｜$7,750（88.6%）\n2. 全能2"
      assert_includes text, "10/4（日）\n1. PDRN1\n  1 個／1 單｜$2,750（100.0%）"

      charts = digest.charts
      assert_equal [0, 2, 3, 4], charts.keys
      assert_equal ["10/3（六）", "10/4（日）"], charts[0][:labels]
      assert_equal [{ name: "舊客", data: [6000, 2750] }, { name: "新客", data: [2750, 0] }], charts[0][:series]
      assert_equal [6000, 2750], charts[2][:series].find { |x| x[:name] == "金卡" }[:data]
      assert_equal [["30-39", 2], ["40-49", 3]], charts[3][:series].map { |x| x.values_at(:name, :slot) } # 顏色跟著年齡層走
      assert_equal 6, charts[2][:series].last[:slot] # 新客固定第 7 色
      assert_equal [{ name: "PDRN1", data: [3, 1] }, { name: "全能2", data: [1, 0] }], charts[4][:series]
      assert_empty LineDigest.new(DAY, line: FakeLine.new).charts # 一天不畫圖
    end

    test "上次發到 10/1、10/2 漏發也不補，只報昨天（after_import 的算法）" do
      LineDigestDelivery.create!(topic: "sales_daily", report_date: Date.new(2026, 10, 1))
      line = FakeLine.new
      assert_equal 1, LineDigest.new(LineDigestDelivery.pending_days("sales_daily", through: DAY), line: line).call
      assert line.sent.first.last.first.start_with?("📊 10/3（六） SL 訂單")
      assert LineDigestDelivery.exists?(topic: "sales_daily", report_date: DAY)
      assert_not LineDigestDelivery.exists?(topic: "sales_daily", report_date: Date.new(2026, 10, 2))
    end

    test "只發給有訂閱的群組，同一天只發一次；當天沒訂單不發" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(DAY, line: line).call
      assert_equal ["Csales"], line.sent.map(&:first)
      assert_equal 0, LineDigest.new(DAY, line: line).call
      assert_equal 0, LineDigest.new(Date.new(2026, 10, 2), line: line).call
      assert_equal 1, line.sent.size
    end
  end
end
