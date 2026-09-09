# frozen_string_literal: true

require "test_helper"

class MessageListsUpgradeInfoTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "upgrade_info_admin@test.com", username: "upgrade_info_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "an upgrade-tier list shows distance-to-next-tier and product info for recipients" do
    # 幾個現有白卡持卡人，讓「下一級銀卡」的門檻估計值有東西可以算
    5.times { |i| ShoplineCustomer.create!(shopline_id: "silver_holder_#{i}", membership_level: "銀卡", total_amount: 50_000 + i * 1000) }

    customer = ShoplineCustomer.create!(shopline_id: "upgraded_1", email: "upgraded@example.com",
                                         membership_level: "白卡", total_amount: 20_000)
    ShoplineOrder.create!(shopline_customer_id: customer.id, email: customer.email, order_number: "#OLD1",
                           product_name: "薑黃", payment_status: "已付款", order_date: 5.days.ago)
    ShoplineOrder.create!(shopline_customer_id: customer.id, email: customer.email, order_number: "#NEW1",
                           product_name: "魚油3", payment_status: "已付款", order_date: 1.day.ago)

    list = MessageList.create!(name: "09/09 升級白卡名單", sent_on: Date.current, target_product: "白卡", source: "daily_snapshot")
    MessageListRecipient.create!(message_list_id: list.id, email: customer.email, full_name: "測試升級客",
                                  shopline_customer_id: customer.id)

    get message_list_path(list, tab: "pending")

    assert_response :success
    assert_includes response.body, "銀卡"
    assert_includes response.body, "本次維護內容"
    assert_includes response.body, "客人目前狀態"
  end

  test "a non-upgrade list does not show the maintenance-log columns" do
    list = MessageList.create!(name: "薑黃回購名單", sent_on: Date.current, target_product: "薑黃", source: "daily_snapshot")
    MessageListRecipient.create!(message_list_id: list.id, email: "b@example.com", full_name: "一般客")

    get message_list_path(list, tab: "pending")

    assert_response :success
    refute_includes response.body, "本次維護內容"
  end
end
