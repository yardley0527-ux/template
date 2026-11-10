# frozen_string_literal: true

require "test_helper"

class MaliciousReturnSyncTest < ActiveSupport::TestCase
  HEADER = ["折讓開立與否", "訂單號碼", "發票號碼", "發票日期", "訂購人", "訂購人EMAIL", "退貨原因", nil].freeze

  setup do
    @bad   = ShoplineCustomer.create!(email: "bad@example.com", full_name: "壞客人")
    @nomail = ShoplineCustomer.create!(email: "nomail@example.com", full_name: "沒填信箱")
    @fine  = ShoplineCustomer.create!(email: "fine@example.com", full_name: "取消訂單的人")
    ShoplineOrder.create!(email: "nomail@example.com", shopline_customer_id: @nomail.id, order_number: "#20260801152414900",
                          product_name: "PDRN1", order_date: 3.months.ago, payment_status: "已付款", quantity: 1)
  end

  def rows
    [
      HEADER,
      ["是", "#20251009151457201", "TH1", Date.new(2025, 10, 13), "壞客人", "BAD@example.com ", nil, "惡意退貨"],
      ["是", "#20260801152414900", "DP1", Date.new(2026, 8, 1), "沒填信箱", nil, nil, "惡意退貨"],
      ["否", "#20260410171840882", "ZJ1", Date.new(2026, 4, 11), "取消訂單的人", "fine@example.com", "取消訂單", nil],
      ["否", "#20260926154040284", "FR1", Date.new(2026, 9, 26), "還沒匯入", nil, nil, "惡意退貨"]
    ]
  end

  test "blacklists customers on 惡意退貨 rows by email or order number, ignores other returns" do
    result = MaliciousReturnSync.call(rows: rows)

    assert @bad.reload.customer_profile.blacklisted
    assert @nomail.reload.customer_profile.blacklisted
    assert_nil @fine.reload.customer_profile
    assert_equal %w[壞客人 沒填信箱].sort, result[:added].sort
    assert_equal ["#20260926154040284"], result[:unmatched]
    assert_equal "partial", SyncRun.latest_for("malicious_returns").status
  end

  test "picks up every order number in a merged cell" do
    entry = MaliciousReturnSync.new.parse([["是", "#20260623170213493  #20260623165953673", "惡意退貨"]]).first
    assert_equal %w[#20260623170213493 #20260623165953673], entry[:orders]
  end

  test "does not re-blacklist a customer someone manually removed" do
    MaliciousReturnSync.call(rows: rows)
    @bad.customer_profile.update!(blacklisted: false)

    result = MaliciousReturnSync.call(rows: rows)

    refute @bad.reload.customer_profile.blacklisted
    assert_empty result[:added]
    assert_equal 1, CustomerEditLog.where(customer_id: @bad.id, section: "malicious_return").count
  end

  test "counts customers already on the blacklist without listing them as new" do
    CustomerProfile.create!(shopline_customer_id: @bad.id, blacklisted: true)

    result = MaliciousReturnSync.call(rows: rows)

    assert_equal ["沒填信箱"], result[:added]
    assert_equal 1, result[:already_blacklisted]
  end
end
