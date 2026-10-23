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

    test "前一天訂單、當月概況、卡別、年齡層、熱銷商品" do
      text = LineDigest.new(DAY, line: FakeLine.new).message

      assert_includes text, "📊 10/3（六） SL 訂單\n訂單 2 單｜營收 $8,750（均 $4,375）\n舊客 1人/1單 $6,000（均 $6,000）\n新客 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "📅 10/1–10/3 業績概況\n累計 $168,750｜未達標 2 天\n（日目標 $150,000）"
      assert_includes text, "10/1（四）✅ 1單 $160,000\n  舊 1單 $160,000｜新 0單 $0\n10/2（五）❌ 0單 $0\n10/3（六）❌ 2單 $8,750"
      assert_includes text, "金卡 1人/1單 $6,000（均 $6,000）\n銀卡 0 人"
      assert_includes text, "新客 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "30-39 1人/1單 $6,000（均 $6,000）\n40-49 1人/1單 $2,750（均 $2,750）"
      assert_includes text, "1. PDRN1\n  3 個／2 單｜$7,750（88.6%）\n2. 全能2\n  1 個／1 單｜$1,000（11.4%）"
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
