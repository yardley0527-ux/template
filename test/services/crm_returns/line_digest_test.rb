# frozen_string_literal: true

require "test_helper"

module CrmReturns
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_texts(to, texts) = @sent << [to, texts]
    end

    DAY = Date.new(2026, 10, 22)

    setup do
      @old_token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"]
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
      LineBotGroup.create!(group_id: "Ccrm", name: "苼莛國際-CRM優質會員", subscriptions: ["crm_returns"])
      LineBotGroup.create!(group_id: "Cbrief", subscriptions: ["order_brief"])

      customer("black@example.com", "黑卡回來", "黑卡", 300_000, ig: "black_ig")
      customer("gold-recent@example.com", "金卡常買", "金卡", 80_000)
      customer("gold-alias@example.com", "金卡分身", "金卡", 90_000, ig: "@alias_ig")
      customer("gold-new@example.com", "金卡沒舊單", "金卡", 50_000)
      customer("silver@example.com", "銀卡回來", "銀卡", 60_000)
      bad = customer("bad@example.com", "黑名單金卡", "金卡", 200_000)
      CustomerProfile.create!(shopline_customer: bad, blacklisted: true)

      order("#B0", "black@example.com", Date.new(2026, 2, 1), 9000)
      order("#B1", "black@example.com", DAY, 12_000, product: "全能3", quantity: 2)
      order("#B1", "black@example.com", DAY, 12_000, product: "薑黃2")        # 同一張單第二行，金額不能重複算
      order("#R0", "gold-recent@example.com", Date.new(2026, 9, 1), 5000)
      order("#R1", "gold-recent@example.com", DAY, 5000)
      order("#A0", "gold-alias@example.com", Date.new(2025, 1, 1), 5000)
      order("#A9", "other@example.com", Date.new(2026, 8, 1), 5000, ig: "Alias_IG") # 分身最近才買過
      order("#A1", "gold-alias@example.com", DAY, 5000)
      order("#N1", "gold-new@example.com", DAY, 50_000)
      order("#S0", "silver@example.com", Date.new(2025, 1, 1), 5000)
      order("#S1", "silver@example.com", DAY, 5000)
      order("#X0", "bad@example.com", Date.new(2025, 1, 1), 5000)
      order("#X1", "bad@example.com", DAY, 5000)
    end

    teardown { ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token }

    def order(number, email, date, total, product: "全能3", quantity: 1, ig: nil)
      ShoplineOrder.create!(order_number: number, email: email, product_name: product, quantity: quantity, instagram_account: ig,
                            total_amount: total, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day, 12))
    end

    def customer(email, name, level, total, ig: nil)
      ShoplineCustomer.create!(email: email, full_name: name, membership_level: level, total_amount: total, instagram_account: ig)
    end

    test "前一天下單、上次購買隔 180 天以上的黑金卡，排除黑名單" do
      text = LineDigest.new(DAY, line: FakeLine.new).message

      assert_includes text, "🔔 久未消費的黑金卡回來了\n10/22（四） 訂單・上次購買已隔 180 天以上\n共 1 人，請跟進"
      assert_includes text, "🖤 黑卡回來｜黑卡\nIG：black_ig\n上次購買 2026/2/1（隔 263 天）\n這次 $12,000\n・全能3 x2\n・薑黃2 x1\n累計 $300,000"
      refute_includes text, "金卡常買"
      refute_includes text, "金卡分身"   # IG 分身 8/1 才買過
      refute_includes text, "金卡沒舊單" # 沒有更早紀錄，可能是新客
      refute_includes text, "銀卡回來"
      assert_includes text, "已排除黑名單 1 人（黑名單金卡）"
    end

    test "只發給有訂閱的群組，同一天只發一次；沒人回來不發" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(DAY, line: line).call
      assert_equal ["Ccrm"], line.sent.map(&:first)
      assert_equal 0, LineDigest.new(DAY, line: line).call
      assert_equal 0, LineDigest.new(DAY - 1, line: line).call
      assert_equal 1, line.sent.size
    end
  end
end
