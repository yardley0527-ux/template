# frozen_string_literal: true

require "test_helper"

module OrderBrief
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
      LineBotGroup.create!(group_id: "Cstrategy", name: "苼莛國際-策略部", subscriptions: ["order_brief"])
      LineBotGroup.create!(group_id: "Cseo", subscriptions: ["seo_daily"])

      ShoplineCustomer.create!(email: "amy@example.com", full_name: "Amy", membership_level: "黑卡", instagram_account: "amy_ig")
      ShoplineCustomer.create!(email: "amy.alt@example.com", full_name: "Amy 分身", instagram_account: "AMY_IG")
      ShoplineCustomer.create!(email: "bob@example.com", full_name: "Bob", membership_level: "銀卡")
      ShoplineCustomer.create!(email: "new@example.com", full_name: "Newbie", instagram_account: "無")
      ShoplineCustomer.create!(email: "x@example.com", full_name: "Xin", instagram_account: "無")

      # Amy：用分身 email 買過 PDRN3，今天回購 PDRN6＋全能
      order("#A1", "amy.alt@example.com", Date.new(2026, 9, 20), [["PDRN3", 1]], 9000)
      order("#A2", "amy@example.com", DAY, [["PDRN6", 1], ["全能1", 2]], 20000)
      # Bob：以前只買過全能，今天第一次買 PDRN；薑黃成對行只算一次
      order("#B1", "bob@example.com", Date.new(2026, 5, 1), [["全能3", 1]], 5000)
      order("#B2", "bob@example.com", DAY, [["預購-PDRN3", 1], ["薑黃3", 1], ["薑黃3送1", 1]], 12000)
      # 新客
      order("#N1", "new@example.com", DAY, [["益生菌2", 1]], 2000)
      # 跟新客同一個「無」IG 不能被當成同一人
      order("#X1", "x@example.com", Date.new(2026, 1, 1), [["魚油1", 1]], 800)
    end

    teardown { ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token }

    def order(number, email, date, items, total)
      items.each do |name, qty|
        ShoplineOrder.create!(order_number: number, email: email, product_name: name, quantity: qty,
                              total_amount: total, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day))
      end
    end

    test "簡報口徑：IG 分身算同一人、新客、卡別、瓶數" do
      text = LineDigest.new(DAY, line: FakeLine.new).messages(Report.new(DAY)).join("\n\n")

      assert_includes text, "📦 10/22 訂單簡報"
      assert_includes text, "共 3 人下單、3 張單，營收 $34,000"
      assert_includes text, "新客 1 人、1 張單，$2,000（占 6%）"
      assert_includes text, "黑卡 1 人，$20,000"
      assert_includes text, "一般會員 1 人（含新客 1 人），$2,000"
      assert_includes text, "PDRN 2 人，付費 9 瓶（預購 3 瓶）"
      assert_includes text, "薑黃 1 人，付費 3 瓶，另送 1 瓶"
      assert_includes text, "【PDRN】2 人：回購 1、舊客第一次買 1、新客 0"
      assert_includes text, "・Amy（黑）：PDRN6、全能1×2，$20,000｜上次 9/20 PDRN3，隔 32 天｜第 2 次買 PDRN，從 3 瓶升到 6 瓶，加購全能"
      assert_includes text, "・Bob（銀）：PDRN3、薑黃3送1，$12,000｜上次消費 5/1，隔 174 天｜上次買全能3"
      assert_includes text, "【很久沒回來買的（≥90 天）】1 人"
      assert_includes text, "其他新客：Newbie（益生菌2，$2,000）"
    end

    test "只發給有訂閱的群組，同一天只發一次" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(DAY, line: line).call
      assert_equal ["Cstrategy"], line.sent.map(&:first)
      assert_equal 0, LineDigest.new(DAY, line: line).call
      assert_equal 1, LineDigest.new(DAY, line: line).call(force: true)
      assert_equal 1, LineDigestDelivery.where(report_date: DAY).count
    end

    test "直播日段落太長時按行切成多則，每則不超過 LINE 上限" do
      long = Struct.new(:sections).new(["標題\n" + Array.new(300) { |i| "・客人#{i}：#{'全能' * 20}" }.join("\n")])
      texts = LineDigest.new(DAY, line: FakeLine.new).messages(long)
      assert texts.size > 1
      assert texts.all? { |t| t.size <= LineBot::Client::MAX_TEXT }
      assert_includes texts.last, "客人299"
    end

    test "當天還沒有訂單（還沒匯入）不發也不記錄" do
      assert_equal 0, LineDigest.new(DAY + 1, line: FakeLine.new).call
      assert_equal 0, LineDigestDelivery.count
    end

    test "推播失敗時拿掉紀錄，下次匯入還能再發" do
      broken = Object.new
      def broken.push_texts(*) = raise(LineBot::Client::Error, "LINE 500")
      assert_raises(LineBot::Client::Error) { LineDigest.new(DAY, line: broken).call }
      assert_equal 0, LineDigestDelivery.count
    end
  end
end
