# frozen_string_literal: true

require "test_helper"

# 客戶商機分頁的黑卡逾期未回購名單：畫面內容、維護動作（聯絡狀態／備註）。
class NotificationBoardBlackOverdueTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @user = User.create!(email: "ops@test.com", username: "ops_user", password: "password123", role: admin_role)
    sign_in @user

    @customer = ShoplineCustomer.create!(email: "vip@example.com", full_name: "黑卡阿姨", membership_level: "黑卡",
                                         total_amount: 520_000, instagram_account: "@vip_ig")
    CrmCustomerProductTracking.create!(
      email: "vip@example.com", product_key: "metabolism", last_order_date: 90.days.ago.to_date, last_order_bottles: 1,
      expected_return_date: Date.current - 12, suggested_reminder_date: Date.current - 19,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    @cycle = CrmCustomerProductCycle.create!(
      identity_key: "vip@example.com", email: "vip@example.com", product_key: "metabolism",
      cycle_started_at: 90.days.ago.to_date, bottle_count: 1, estimated_usage_days: 60,
      estimated_finish_date: Date.current - 12, suggested_contact_date: Date.current - 19,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
  end

  test "customer_opportunity section shows the black-card list with name, IG link and cumulative spend" do
    get notification_board_path(section: "customer_opportunity")

    assert_response :success
    assert_select "h5", text: "黑卡逾期未回購名單"
    assert_select "a[href=?]", customer_path(@customer), text: "黑卡阿姨"
    assert_select "a[href=?]", "https://instagram.com/vip_ig"
    assert_includes response.body, "NT$520,000"
    assert_includes response.body, "12 天"
  end

  test "customer_opportunity section shows only the list, no notification cards below it" do
    Notification.create!(
      notification_key: "vip_silent_90_179", kind: "opportunity", category: "vip_silent", severity: "opportunity",
      priority: "P2", title: "黑/金卡沉睡 90–179 天：31 位", deduplication_key: "vip:#{SecureRandom.hex(4)}",
      status: "detected", first_detected_at: Time.current, last_detected_at: Time.current
    )

    get notification_board_path(section: "customer_opportunity")

    assert_select "h5", text: "黑卡逾期未回購名單"
    assert_not_includes response.body, "黑/金卡沉睡 90–179 天"
    assert_not_includes response.body, "其他客戶商機提醒"
  end

  test "products without a list still get a tab marked 尚未有名單, listed after the products that have one" do
    groups = BlackOverdueList.call

    assert_equal JourneyProducts::PRODUCTS.keys.sort, groups.map(&:product_key).sort, "every tracked product has a tab"
    assert_equal "metabolism", groups.first.product_key, "products with a list come first"
    assert groups.last.rows.empty?

    get notification_board_path(section: "customer_opportunity")
    assert_select "a.nav-link", text: /魚油.*尚未有名單/m
    assert_select "a.nav-link", text: /穀胱甘肽.*尚未有名單/m
    assert_includes response.body, "穀胱甘肽屬波段補貨"
  end

  test "non-black customers never appear in the list" do
    ShoplineCustomer.create!(email: "gold@example.com", full_name: "金卡阿姨", membership_level: "金卡", total_amount: 900_000)
    CrmCustomerProductTracking.create!(
      email: "gold@example.com", product_key: "metabolism", last_order_date: 90.days.ago.to_date, last_order_bottles: 1,
      expected_return_date: Date.current - 12, suggested_reminder_date: Date.current - 19,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )

    get notification_board_path(section: "customer_opportunity")

    assert_not_includes response.body, "金卡阿姨"
  end

  test "recording a contact status with a note updates the cycle and shows on the list" do
    post notification_board_black_overdue_follow_up_path,
         params: { cycle_id: @cycle.id, product_key: "metabolism", follow_up_action: "contacted_waiting_reply", note: "客人說月底再買" }

    assert_redirected_to notification_board_path(section: "customer_opportunity", bo_product: "metabolism")
    assert_equal "waiting_reply", @cycle.reload.follow_up_status
    event = CrmCustomerProductFollowUpEvent.find_by!(cycle_id: @cycle.id)
    assert_equal "客人說月底再買", event.note
    assert_equal @user.id, event.performed_by_user_id

    get notification_board_path(section: "customer_opportunity")
    assert_includes response.body, "客人說月底再買"
    assert_includes response.body, "等待回覆"
  end

  test "note-only requires a note and does not change status" do
    post notification_board_black_overdue_follow_up_path,
         params: { cycle_id: @cycle.id, product_key: "metabolism", follow_up_action: "note_only", note: "" }

    assert_equal "只寫備註時請填寫備註內容", flash[:alert]
    assert_nil @cycle.reload.follow_up_status
    assert_equal 0, CrmCustomerProductFollowUpEvent.count
  end

  test "an unknown action is rejected" do
    post notification_board_black_overdue_follow_up_path,
         params: { cycle_id: @cycle.id, product_key: "metabolism", follow_up_action: "delete_everything" }

    assert_equal "請選擇要記錄的狀態", flash[:alert]
    assert_equal 0, CrmCustomerProductFollowUpEvent.count
  end

  test "cleanse powder (qingxian) rows find their cycle stored under the crm product key" do
    CrmCustomerProductTracking.create!(
      email: "vip@example.com", product_key: "qingxian", last_order_date: 90.days.ago.to_date, last_order_bottles: 1,
      expected_return_date: Date.current - 8, suggested_reminder_date: Date.current - 15,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    cycle = CrmCustomerProductCycle.create!(
      identity_key: "vip@example.com", email: "vip@example.com", product_key: "cleanse_powder",
      cycle_started_at: 90.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: Date.current - 8, suggested_contact_date: Date.current - 15,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )

    group = BlackOverdueList.call.find { |g| g.product_key == "qingxian" }

    assert_equal cycle.id, group.rows.first[:cycle].id
  end

  test "a customer marked paused sinks below customers still to contact" do
    ShoplineCustomer.create!(email: "poor@example.com", full_name: "消費較低", membership_level: "黑卡", total_amount: 1_000)
    CrmCustomerProductTracking.create!(
      email: "poor@example.com", product_key: "metabolism", last_order_date: 90.days.ago.to_date, last_order_bottles: 1,
      expected_return_date: Date.current - 10, suggested_reminder_date: Date.current - 17,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    CrmCustomerProductCycleFollowUpService.call(cycle: @cycle, actor: @user, action: "paused")

    rows = BlackOverdueList.call.find { |g| g.product_key == "metabolism" }.rows

    assert_equal %w[poor@example.com vip@example.com], rows.map { |r| r[:email] }, "paused customer goes last even with higher spend"
  end
end
