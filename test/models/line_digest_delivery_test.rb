# frozen_string_literal: true

require "test_helper"

class LineDigestDeliveryTest < ActiveSupport::TestCase
  SUNDAY = Date.new(2026, 10, 25)

  test "星期一匯入：上次發到星期四，就報五～日" do
    LineDigestDelivery.create!(topic: "sales_daily", report_date: Date.new(2026, 10, 22))
    assert_equal Date.new(2026, 10, 23)..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
  end

  test "平日從沒發過、或已經發到那天，只報那一天" do
    thursday = Date.new(2026, 10, 22)
    assert_equal thursday..thursday, LineDigestDelivery.pending_days("sales_daily", through: thursday)
    LineDigestDelivery.create!(topic: "sales_daily", report_date: thursday)
    assert_equal thursday..thursday, LineDigestDelivery.pending_days("sales_daily", through: thursday)
    LineDigestDelivery.create!(topic: "sales_daily", report_date: SUNDAY)
    assert_equal SUNDAY..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
  end

  test "之前漏發的不補：上次發到很久以前，平日只報昨天、星期一只報五～日" do
    LineDigestDelivery.create!(topic: "sales_daily", report_date: Date.new(2026, 9, 1))
    LineDigestDelivery.create!(topic: "order_brief", report_date: Date.new(2026, 10, 24))
    assert_equal Date.new(2026, 10, 23)..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
    wednesday = Date.new(2026, 10, 28)
    assert_equal wednesday..wednesday, LineDigestDelivery.pending_days("sales_daily", through: wednesday)
  end

  test "星期一：五六已經發過就只報日" do
    LineDigestDelivery.create!(topic: "order_brief", report_date: Date.new(2026, 10, 24))
    assert_equal SUNDAY..SUNDAY, LineDigestDelivery.pending_days("order_brief", through: SUNDAY)
  end
end
