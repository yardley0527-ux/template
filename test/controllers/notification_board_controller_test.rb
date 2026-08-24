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
      severity: "warning", priority: "P2", title: "測試通知", message: "測試訊息",
      deduplication_key: "test_rule:none:#{SecureRandom.hex(4)}",
      status: "detected", first_detected_at: Time.current, last_detected_at: Time.current
    }.merge(attrs))
  end

  test "index defaults to the today section" do
    get notification_board_path
    assert_response :success
    assert_select "li.nav-item a.active", text: /今日待處理/
  end

  test "today includes a P0/P1 notification first detected today" do
    n = build_notification(priority: "P1", title: "今天新發生的高優先", first_detected_at: Time.current)
    get notification_board_path(section: "today")
    assert_includes response.body, n.title
  end

  test "today excludes a plain P2/P3 notification with no due date and no special status (not lost, just not urgent-today)" do
    build_notification(priority: "P3", title: "低優先觀察卡", status: "detected")
    get notification_board_path(section: "today")
    assert_not_includes response.body, "低優先觀察卡"
  end

  test "today includes a non-critical notification detected on an earlier day as long as it is overdue (spec: no longer first-detected-today-only)" do
    build_notification(priority: "P2", title: "跨日仍待處理", first_detected_at: 5.days.ago, last_detected_at: 5.days.ago,
                       due_at: 1.hour.ago)
    get notification_board_path(section: "today")
    assert_includes response.body, "跨日仍待處理"
  end

  test "today includes any pending_assignment notification regardless of when it was first detected" do
    build_notification(priority: "P1", status: "pending_assignment", title: "待分派舊卡",
                       first_detected_at: 10.days.ago, last_detected_at: 10.days.ago)
    get notification_board_path(section: "today")
    assert_includes response.body, "待分派舊卡"
  end

  test "today includes a high-priority pending_verification notification" do
    build_notification(priority: "P0", status: "pending_verification", title: "待系統確認",
                       first_detected_at: 10.days.ago, last_detected_at: 10.days.ago)
    get notification_board_path(section: "today")
    assert_includes response.body, "待系統確認"
  end

  test "today includes a snoozed notification whose snoozed_until just passed" do
    n = build_notification(priority: "P2", status: "in_progress", title: "延後後醒來",
                           first_detected_at: 10.days.ago, last_detected_at: 10.days.ago)
    n.snooze!(until_at: 1.hour.ago, reason: "test")
    get notification_board_path(section: "today")
    assert_includes response.body, "延後後醒來"
    assert_equal "in_progress", n.reload.status, "visiting the board must wake the snooze"
  end

  test "customer_opportunity section only shows the customer-opportunity categories" do
    build_notification(category: "customer_runout", title: "商機卡")
    build_notification(category: "system_health", title: "系統卡")
    get notification_board_path(section: "customer_opportunity")
    assert_includes response.body, "商機卡"
    assert_not_includes response.body, "系統卡"
  end

  test "inventory section only shows inventory_attention" do
    build_notification(category: "inventory_attention", title: "庫存卡")
    build_notification(category: "customer_overdue", title: "商機卡2")
    get notification_board_path(section: "inventory")
    assert_includes response.body, "庫存卡"
    assert_not_includes response.body, "商機卡2"
  end

  test "product_revenue section only shows product_attention" do
    build_notification(category: "product_attention", title: "營收卡")
    build_notification(category: "inventory_attention", title: "庫存卡3")
    get notification_board_path(section: "product_revenue")
    assert_includes response.body, "營收卡"
    assert_not_includes response.body, "庫存卡3"
  end

  test "livestream_event section shows the 5 livestream categories" do
    build_notification(category: "livestream_schedule_gap", title: "週期缺口卡")
    build_notification(category: "system_health", title: "不該出現的系統卡")
    get notification_board_path(section: "livestream_event")
    assert_includes response.body, "週期缺口卡"
    assert_not_includes response.body, "不該出現的系統卡"
  end

  test "system_health section shows system_health notifications and the status lights table" do
    build_notification(category: "system_health", title: "系統健康卡")
    get notification_board_path(section: "system_health")
    assert_includes response.body, "系統健康卡"
    assert_includes response.body, "資料來源狀態"
  end

  test "completed section lists resolved and dismissed notifications, not active ones" do
    resolved = build_notification(title: "已處理卡")
    resolved.auto_resolve!
    build_notification(title: "還開著")

    get notification_board_path(section: "completed")
    assert_includes response.body, "已處理卡"
    assert_not_includes response.body, "還開著"
  end

  test "empty state renders when a section has no notifications" do
    get notification_board_path(section: "customer_opportunity")
    assert_includes response.body, "目前沒有客戶商機提醒"
  end

  test "tab badge counts equal the number of active notifications in that category set (not unread, not customer count)" do
    3.times { |i| build_notification(category: "inventory_attention", title: "庫存#{i}") }
    build_notification(category: "inventory_attention", status: "resolved", resolved_at: Time.current, title: "已結案不算")
    get notification_board_path(section: "inventory")
    assert_select "li.nav-item a .badge", text: "3"
  end

  test "mark_read marks the notification read, does not change status, and redirects back to the section" do
    n = build_notification
    post notification_board_mark_read_path(n, section: "system_health")
    assert_redirected_to notification_board_path(section: "system_health")
    n.reload
    assert n.read?
    assert_equal "detected", n.status, "read is not the same as done (spec section 二 rule 1)"
  end

  test "assign sets owner and due_at, moving the notification to in_progress" do
    n = build_notification(status: "pending_assignment")
    post notification_board_assign_path(n, section: "system_health"),
      params: { owner_user_id: @user.id, due_at: "2026-09-01 10:00" }
    n.reload
    assert_equal @user.id, n.owner_user_id
    assert_equal "in_progress", n.status
  end

  test "start self-claims a detected notification" do
    n = build_notification(status: "detected")
    post notification_board_start_path(n, section: "system_health")
    n.reload
    assert_equal "in_progress", n.status
    assert_equal @user.id, n.owner_user_id
  end

  test "request_verification requires a reason and moves to pending_verification, not resolved" do
    n = build_notification(status: "in_progress")
    post notification_board_request_verification_path(n, section: "system_health"), params: {}
    assert_equal "in_progress", n.reload.status, "must reject without a reason"

    post notification_board_request_verification_path(n, section: "system_health"),
      params: { resolution_reason: "已重新匯入" }
    n.reload
    assert_equal "pending_verification", n.status
    assert_nil n.resolved_at, "only the engine's next run can actually resolve it"
  end

  test "snooze requires both a resume date and a reason" do
    n = build_notification(status: "in_progress")
    post notification_board_snooze_path(n, section: "system_health"), params: { snoozed_until: "" }
    assert_equal "in_progress", n.reload.status

    post notification_board_snooze_path(n, section: "system_health"),
      params: { snoozed_until: 3.days.from_now.to_date.to_s, snooze_reason: "等客戶回覆" }
    n.reload
    assert_equal "snoozed", n.status
    assert_equal "等客戶回覆", n.snooze_reason
  end

  test "dismiss requires a reason" do
    n = build_notification
    post notification_board_dismiss_path(n, section: "system_health"), params: {}
    assert_equal "detected", n.reload.status

    post notification_board_dismiss_path(n, section: "system_health"), params: { dismissal_reason: "not_applicable" }
    assert_equal "dismissed", n.reload.status
  end

  test "dismiss on a P0/P1 notification rejects misjudged/not_applicable and requires known_risk or permanently_excluded" do
    n = build_notification(priority: "P0")
    post notification_board_dismiss_path(n, section: "system_health"), params: { dismissal_reason: "misjudged" }
    assert_equal "detected", n.reload.status, "P0 must not be dismissible with a weak reason"

    post notification_board_dismiss_path(n, section: "system_health"), params: { dismissal_reason: "known_risk" }
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

  test "today groups product-tied categories (customer_overdue/customer_runout/promotion_opportunity) by product, and leaves vip_silent as a standalone card" do
    build_notification(category: "customer_overdue", status: "pending_assignment", priority: "P1",
                       title: "代謝錠逾期未回購", metadata: { "product_key" => "metabolism", "count" => 5 })
    build_notification(category: "vip_silent", status: "pending_assignment", priority: "P1", title: "黑金卡沉睡")

    get notification_board_path(section: "today")
    assert_response :success
    assert_includes response.body, "代謝錠"
    assert_includes response.body, "查看並建立聯絡名單"
    assert_includes response.body, "黑金卡沉睡"
    assert_includes response.body, "其他待處理"
  end

  test "two notifications for the same product are merged into a single product group" do
    build_notification(category: "customer_overdue", status: "pending_assignment", priority: "P1",
                       title: "代謝錠逾期未回購(1-14天)", metadata: { "product_key" => "metabolism", "count" => 5 })
    build_notification(category: "promotion_opportunity", status: "pending_assignment", priority: "P1",
                       title: "代謝錠官網優惠機會", metadata: { "product_key" => "metabolism", "count" => 3 })

    get notification_board_path(section: "today")
    assert_response :success
    # 8 位待聯繫 = 5 + 3（同一組的合計，不是兩張獨立卡片各自的數字）
    assert_includes response.body, "8 位待聯繫"
  end

  test "product_customers renders the merged, live-rechecked list for a product" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    ShoplineCustomer.create!(email: "a@example.com", full_name: "阿明")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    build_notification(category: "customer_runout", status: "pending_assignment", priority: "P1",
                       title: "代謝錠即將用完", metadata: {
                         "product_key" => "metabolism",
                         "query" => { "product_key" => "metabolism", "expected_return_date_from" => Date.current.to_s,
                                      "expected_return_date_to" => (Date.current + 7).to_s }
                       })

    get notification_board_product_customers_path(product_key: "metabolism")
    assert_response :success
    assert_includes response.body, "阿明"
  end

  test "create_product_customer_task creates a follow-up without being tied to a single notification id" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    cycle = CrmCustomerProductCycle.create!(
      identity_key: "a@example.com", email: "a@example.com", product_key: "metabolism",
      cycle_started_at: 40.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: 10.days.ago.to_date, suggested_contact_date: 5.days.ago.to_date,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )

    post notification_board_create_product_customer_task_path,
      params: { product_key: "metabolism", emails: ["a@example.com"], contact_date: Date.current.to_s }

    assert_equal "rescheduled", cycle.reload.follow_up_status
  end

  test "create_customer_task creates a follow-up on the matching cycle and skips customers with an existing active task" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    cycle_a = CrmCustomerProductCycle.create!(
      identity_key: "a@example.com", email: "a@example.com", product_key: "metabolism",
      cycle_started_at: 40.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: 10.days.ago.to_date, suggested_contact_date: 5.days.ago.to_date,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
    cycle_b = CrmCustomerProductCycle.create!(
      identity_key: "b@example.com", email: "b@example.com", product_key: "metabolism",
      cycle_started_at: 40.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: 10.days.ago.to_date, suggested_contact_date: 5.days.ago.to_date,
      match_status: "not_yet_repurchased", follow_up_status: "waiting_reply", refreshed_at: Time.current
    )
    n = build_notification(category: "customer_overdue", metadata: { "query" => { "product_key" => "metabolism" } })

    post notification_board_create_customer_task_path(n),
      params: { emails: ["a@example.com", "b@example.com"], contact_date: Date.current.to_s }

    assert_equal "rescheduled", cycle_a.reload.follow_up_status
    assert_equal "waiting_reply", cycle_b.reload.follow_up_status, "must not overwrite an existing active task"
  end

  test "an unauthenticated visitor is redirected to sign in" do
    delete destroy_user_session_path
    get notification_board_path
    assert_response :redirect
  end
end
