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

  test "maps returned product names to tags, falling back to the original product" do
    row = Array.new(11)
    row[0], row[1], row[7] = "是", "#20260717183122856", "惡意退貨"
    row[8]  = "「年中慶購物節」巔峰代謝女神組(代謝錠+日本清纖粉+益生菌)"
    row[10] = "退貨  (日本清纖粉+益生菌)"
    assert_equal %w[清纖粉 益生菌], MaliciousReturnSync.new.parse([row]).first[:tags]

    row[10] = "尚未出貨"
    row[8]  = "光透冰晶蕃茄白藜蘆醇亮妍膠囊（3瓶）"
    assert_equal %w[冰晶番茄], MaliciousReturnSync.new.parse([row]).first[:tags]

    assert_equal %w[PDRN], MaliciousReturnSync.tags_for("日本專利北海道鮭魚精華膠囊（1瓶）*2")
    assert_equal %w[全能], MaliciousReturnSync.tags_for("維生素B鋅C 全能膠囊 (17瓶) 送3瓶B群")
  end

  test "removes returned-product tags and purges every message list, old ones included" do
    CustomerProfile.create!(shopline_customer_id: @nomail.id, shengting_product_tags: %w[PDRN 代謝錠], product_tags: %w[鋅])
    @bad.update!(instagram_account: "@badgirl")
    alt = ShoplineCustomer.create!(email: "bad.alt@example.com", full_name: "壞客人分身", instagram_account: "badgirl")
    old_list = MessageList.create!(name: "舊名單", sent_on: 1.year.ago.to_date, target_product: "PDRN")
    new_list = MessageList.create!(name: "新名單", sent_on: Date.current, target_product: "代謝錠")
    [[old_list, "nomail@example.com"], [old_list, "fine@example.com"], [new_list, "BAD@example.com"], [new_list, alt.email]]
      .each { |list, email| MessageListRecipient.create!(message_list: list, email: email) }

    result = MaliciousReturnSync.call(rows: rows) # 沒填信箱那列沒有品名 → 用訂單品名 PDRN1

    profile = @nomail.reload.customer_profile
    assert_equal %w[代謝錠], profile.shengting_product_tags
    assert_equal %w[鋅], profile.product_tags
    assert_equal({ "沒填信箱" => ["PDRN"] }, result[:tags_removed])
    assert_equal ["fine@example.com"], MessageListRecipient.pluck(:email)
    assert_equal 3, result[:recipients_removed].values.sum
  end

  test "leaves tags and lists alone once someone takes the customer off the blacklist" do
    MaliciousReturnSync.call(rows: rows)
    @nomail.customer_profile.update!(blacklisted: false, shengting_product_tags: %w[PDRN])
    list = MessageList.create!(name: "名單", sent_on: Date.current, target_product: "PDRN")
    MessageListRecipient.create!(message_list: list, email: "nomail@example.com")

    MaliciousReturnSync.call(rows: rows)

    assert_equal %w[PDRN], @nomail.reload.customer_profile.shengting_product_tags
    assert_equal 1, list.recipients.count
  end

  test "counts customers already on the blacklist without listing them as new" do
    CustomerProfile.create!(shopline_customer_id: @bad.id, blacklisted: true)

    result = MaliciousReturnSync.call(rows: rows)

    assert_equal ["沒填信箱"], result[:added]
    assert_equal 1, result[:already_blacklisted]
  end
end
