# frozen_string_literal: true

require "test_helper"

module CrmBirthdays
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_texts(to, texts) = @sent << [to, texts]
    end

    WEDNESDAY = Date.new(2026, 10, 28) # 該週 10/26（一）–11/1（日）

    setup do
      @old_token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"]
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
      LineBotGroup.create!(group_id: "Ccrm", name: "苼莛國際-CRM優質會員", subscriptions: ["crm_birthdays"])
      LineBotGroup.create!(group_id: "Cseo", subscriptions: ["seo_daily"])

      customer("black@example.com", "黑卡客", "黑卡", Date.new(1990, 10, 27), 300_000)
      customer("gold-later@example.com", "金卡下週", "金卡", Date.new(1985, 11, 3), 80_000)      # 不是本週
      customer("silver@example.com", "銀卡大戶", "銀卡", Date.new(1992, 11, 10), 60_000)        # 3 週內、高消費
      customer("white-small@example.com", "白卡小額", "白卡", Date.new(1992, 10, 29), 20_000)   # 消費不夠
      customer("far@example.com", "太遠", "銀卡", Date.new(1992, 11, 20), 90_000)               # 超過 3 週
      bad = customer("bad@example.com", "黑名單金卡", "金卡", Date.new(1991, 10, 30), 200_000)
      CustomerProfile.create!(shopline_customer: bad, blacklisted: true)

      ShoplineOrder.create!(order_number: "#B1", email: "black@example.com", product_name: "全能3", quantity: 1,
                            total_amount: 5000, payment_status: "已付款", order_date: Time.utc(2026, 9, 1))
    end

    teardown { ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token }

    def customer(email, name, level, birthdate, total)
      ShoplineCustomer.create!(email: email, full_name: name, membership_level: level, birthdate: birthdate, total_amount: total)
    end

    test "本週黑金卡生日＋3 週內高消費非黑金卡，排除黑名單" do
      text = LineDigest.new(WEDNESDAY, line: FakeLine.new).message

      assert_includes text, "🎂 生日名單 10/26（一）–11/1（日）"
      assert_includes text, "【黑金卡本週生日】1 人\n・10/27（二） 黑卡客（黑）｜累計 $300,000｜最近購買 2026/9/1"
      refute_includes text, "金卡下週"
      assert_includes text, "接下來 3 週生日（到 11/15（日））1 人\n・11/10（二） 銀卡大戶（銀）｜累計 $60,000｜沒有購買紀錄"
      refute_includes text, "白卡小額"
      refute_includes text, "太遠"
      assert_includes text, "已排除黑名單 1 人（黑名單金卡）"
    end

    test "只發給有訂閱的群組，同一週只發一次" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(WEDNESDAY, line: line).call
      assert_equal ["Ccrm"], line.sent.map(&:first)
      assert_equal 0, LineDigest.new(WEDNESDAY + 1, line: line).call
      assert_equal 1, LineDigestDelivery.where(topic: "crm_birthdays", report_date: Date.new(2026, 10, 26)).count
    end
  end
end
