# frozen_string_literal: true

require "test_helper"

class LineReportResendJobTest < ActiveSupport::TestCase
  class FakeLine
    attr_reader :sent

    def initialize = @sent = []
    def push_texts(to, texts) = @sent << [to, texts]
    def push_text(to, text) = @sent << [to, [text]]
  end

  TODAY = Date.new(2026, 10, 7) # 星期三
  DAY = TODAY - 1

  setup do
    @old_token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"]
    ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = "token"
    @sales = LineBotGroup.create!(group_id: "Csales", name: "苼莛國際-銷售後台", subscriptions: ["sales_daily"])
    @late = LineBotGroup.create!(group_id: "Clate", name: "晚勾的群組", subscriptions: ["sales_daily"])
    ShoplineCustomer.create!(email: "gold@example.com", full_name: "金卡客", membership_level: "金卡", birthdate: Date.new(1990, 5, 1))
    travel_to TODAY.in_time_zone.change(hour: 11)
  end

  teardown { ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"] = @old_token }

  def add_order
    ShoplineOrder.create!(order_number: "#G1", email: "gold@example.com", product_name: "PDRN1", quantity: 1, total_amount: 2750,
                          checkout_amount: 2750, payment_status: "已付款", order_date: Time.utc(DAY.year, DAY.month, DAY.day, 12))
  end

  def run_job(group)
    line = FakeLine.new
    job = LineReportResendJob.new
    job.line = line
    job.perform(group.id)
    line.sent
  end

  test "星期一補五～日，其他天補昨天" do
    assert_equal Date.new(2026, 10, 2)..Date.new(2026, 10, 4), LineReportResendJob.days(Date.new(2026, 10, 5))
    assert_equal DAY..DAY, LineReportResendJob.days(TODAY)
  end

  test "那天已經發過：只補發給這個群組，其他群組不重收" do
    add_order
    LineDigestDelivery.create!(topic: "sales_daily", report_date: DAY, group_count: 1)

    sent = run_job(@late)

    assert_equal ["Clate"], sent.map(&:first)
    assert_includes sent.first.last.join, "SL 訂單"
    assert_equal 1, LineDigestDelivery.find_by(topic: "sales_daily", report_date: DAY).group_count
  end

  test "那天還沒發過：照正常流程發給所有訂閱群組並記成已發" do
    add_order

    sent = run_job(@late)

    assert_equal %w[Csales Clate].sort, sent.map(&:first).sort
    assert_equal 2, LineDigestDelivery.find_by(topic: "sales_daily", report_date: DAY).group_count
  end

  test "還沒匯入訂單：在群組說明沒有報告可以發" do
    sent = run_job(@late)

    assert_equal 1, sent.size
    assert_equal "Clate", sent.first.first
    assert_includes sent.first.last.first, "10/6 沒有可以發的報告"
    assert_nil LineDigestDelivery.find_by(topic: "sales_daily", report_date: DAY)
  end
end
