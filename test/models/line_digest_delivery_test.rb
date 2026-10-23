# frozen_string_literal: true

require "test_helper"

class LineDigestDeliveryTest < ActiveSupport::TestCase
  SUNDAY = Date.new(2026, 10, 25)

  test "星期一匯入：上次發到星期四，就報五～日" do
    LineDigestDelivery.create!(topic: "sales_daily", report_date: Date.new(2026, 10, 22))
    assert_equal Date.new(2026, 10, 23)..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
  end

  test "從沒發過、或已經發到那天，只報那一天" do
    assert_equal SUNDAY..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
    LineDigestDelivery.create!(topic: "sales_daily", report_date: SUNDAY)
    assert_equal SUNDAY..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
  end

  test "很久沒發最多往回 7 天，其他 topic 不影響" do
    LineDigestDelivery.create!(topic: "sales_daily", report_date: Date.new(2026, 9, 1))
    LineDigestDelivery.create!(topic: "order_brief", report_date: Date.new(2026, 10, 24))
    assert_equal Date.new(2026, 10, 19)..SUNDAY, LineDigestDelivery.pending_days("sales_daily", through: SUNDAY)
  end
end
