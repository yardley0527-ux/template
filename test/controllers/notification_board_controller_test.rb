# frozen_string_literal: true

require "test_helper"

class NotificationBoardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @user = User.create!(email: "ops@test.com", username: "ops_user", password: "password123", role: admin_role)
    sign_in @user
  end

  def build_notification(attrs = {})
    Notification.create!({
      notification_key: "test_rule", kind: "alert", category: "system_health",
      severity: "warning", title: "測試通知", message: "測試訊息",
      deduplication_key: "test_rule:none:#{SecureRandom.hex(4)}",
      status: "open", first_detected_at: Time.current, last_detected_at: Time.current
    }.merge(attrs))
  end

  test "index defaults to the today section" do
    get notification_board_path
    assert_response :success
    assert_select "li.nav-item a.active", text: /今日注意/
  end

  test "today section shows critical notifications regardless of category" do
    n = build_notification(severity: "critical", title: "緊急事項A")
    get notification_board_path(section: "today")
    assert_response :success
    assert_includes response.body, n.title
  end

  test "today section excludes a non-critical notification detected on an earlier day" do
    build_notification(severity: "opportunity", title: "舊的機會", first_detected_at: 3.days.ago, last_detected_at: 3.days.ago)
    get notification_board_path(section: "today")
    assert_not_includes response.body, "舊的機會"
  end

  test "today section is capped at 8 cards" do
    10.times { |i| build_notification(severity: "critical", title: "緊急#{i}") }
    get notification_board_path(section: "today")
    assert_select ".notification-card, .card.border-0.shadow-sm", count: 8
  end

  test "opportunities section only shows the 4 customer-opportunity categories" do
    build_notification(category: "customer_runout", title: "商機卡")
    build_notification(category: "system_health", title: "系統卡")
    get notification_board_path(section: "opportunities")
    assert_includes response.body, "商機卡"
    assert_not_includes response.body, "系統卡"
  end

  test "products section only shows inventory_attention and product_attention" do
    build_notification(category: "inventory_attention", title: "庫存卡")
    build_notification(category: "customer_runout", title: "商機卡2")
    get notification_board_path(section: "products")
    assert_includes response.body, "庫存卡"
    assert_not_includes response.body, "商機卡2"
  end

  test "system section shows system_health notifications and the status lights table" do
    build_notification(category: "system_health", title: "系統健康卡")
    get notification_board_path(section: "system")
    assert_includes response.body, "系統健康卡"
    assert_includes response.body, "資料來源狀態"
  end

  test "completed section lists resolved and dismissed notifications, not open ones" do
    resolved = build_notification(title: "已處理卡")
    resolved.resolve!
    build_notification(title: "還開著")

    get notification_board_path(section: "completed")
    assert_includes response.body, "已處理卡"
    assert_not_includes response.body, "還開著"
  end

  test "empty state renders when a section has no notifications" do
    get notification_board_path(section: "opportunities")
    assert_includes response.body, "目前沒有客戶商機提醒"
  end

  test "mark_read marks the notification read and redirects back to the section" do
    n = build_notification
    post notification_board_mark_read_path(n, section: "system")
    assert_redirected_to notification_board_path(section: "system")
    assert n.reload.read?
  end

  test "resolve marks the notification resolved" do
    n = build_notification
    post notification_board_resolve_path(n, section: "system")
    assert_equal "resolved", n.reload.status
  end

  test "dismiss marks the notification dismissed" do
    n = build_notification
    post notification_board_dismiss_path(n, section: "system")
    assert_equal "dismissed", n.reload.status
  end

  test "customers action renders the live-rechecked list for an expandable category" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    ShoplineCustomer.create!(email: "a@example.com", full_name: "阿明")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    n = build_notification(category: "customer_runout", metadata: {
      "query" => { "product_key" => "metabolism", "expected_return_date_from" => Date.current.to_s,
                   "expected_return_date_to" => (Date.current + 7).to_s }
    })

    get notification_board_customers_path(n)
    assert_response :success
    assert_includes response.body, "阿明"
  end

  test "a non-expandable category's customers action renders the empty-list message" do
    n = build_notification(category: "system_health")
    get notification_board_customers_path(n)
    assert_response :success
    assert_includes response.body, "目前沒有符合條件的客人"
  end

  test "an unauthenticated visitor is redirected to sign in" do
    delete destroy_user_session_path
    get notification_board_path
    assert_response :redirect
  end
end
