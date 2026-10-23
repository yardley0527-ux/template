# frozen_string_literal: true

require "test_helper"

module OrderBrief
  class LineDigestTest < ActiveSupport::TestCase
    class FakeLine
      attr_reader :sent

      def initialize = @sent = []
      def push_messages(to, messages) = @sent << [to, messages]
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
      r = Report.new(DAY)
      s = r.summary
      assert_equal [3, 3, 34_000], s.values_at(:people, :orders, :revenue)
      assert_equal [1, 2000, 6], s.values_at(:new_people, :new_revenue, :new_share)

      black = r.level_stats.find { |l| l[:level] == "黑卡" }
      assert_equal [1, 20_000], black.values_at(:people, :amount)
      assert_equal 1, r.level_stats.find { |l| l[:level] == "一般會員" }[:new_people]

      pdrn = r.product_stats.find { |p| p[:series] == "PDRN" }
      assert_equal [2, 9, 3], pdrn.values_at(:people, :paid, :pre)
      turmeric = r.product_stats.find { |p| p[:series] == "薑黃" }
      assert_equal [3, 1], turmeric.values_at(:paid, :gift)

      f = r.focus("PDRN")
      assert_equal [2, 1, 1, 0], [f[:buyers], f[:repeat].size, f[:first].size, f[:fresh].size]
      amy = f[:repeat].first
      assert_equal ["Amy", "黑", 32], amy.values_at(:name, :level, :gap)
      assert_equal "第 2 次買 PDRN，從 3 瓶升到 6 瓶，加購全能", amy[:note]
      bob = f[:first].first
      assert_equal ["Bob", 174, "全能3"], bob.values_at(:name, :gap, :last_items)

      assert_equal ["Bob"], r.long_gap.map { |e| e[:name] }
      assert_equal ["Amy"], r.back_within.map { |e| e[:name] }
      assert_equal ["Newbie"], r.other_new.map { |e| e[:name] }
    end

    test "Flex 卡片：總覽表格＋明細頁按鈕" do
      flex = FlexMessage.new(Report.new(DAY)).to_h
      json = flex.to_json
      assert_equal "flex", flex[:type]
      assert_equal "📦 10/22（四） 訂單簡報：3 人、3 張單，營收 $34,000", flex[:altText]
      assert_includes json, "$34,000"
      assert_includes json, "$2,000（6%）"
      assert_includes json, "https://st-crm-v2.onrender.com/order_briefs?date=2026-10-22"
      # LINE 不接受空字串的 text
      refute_includes json, '"text":""'
    end

    test "只發給有訂閱的群組，同一天只發一次" do
      line = FakeLine.new
      assert_equal 1, LineDigest.new(DAY, line: line).call
      assert_equal ["Cstrategy"], line.sent.map(&:first)
      assert_equal 0, LineDigest.new(DAY, line: line).call
      assert_equal 1, LineDigest.new(DAY, line: line).call(force: true)
      assert_equal 1, LineDigestDelivery.where(report_date: DAY).count
    end

    test "當天還沒有訂單（還沒匯入）不發也不記錄" do
      assert_equal 0, LineDigest.new(DAY + 1, line: FakeLine.new).call
      assert_equal 0, LineDigestDelivery.count
    end

    test "推播失敗時拿掉紀錄，下次匯入還能再發" do
      broken = Object.new
      def broken.push_messages(*) = raise(LineBot::Client::Error, "LINE 500")
      assert_raises(LineBot::Client::Error) { LineDigest.new(DAY, line: broken).call }
      assert_equal 0, LineDigestDelivery.count
    end
  end
end
