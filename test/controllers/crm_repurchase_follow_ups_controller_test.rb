# frozen_string_literal: true

require "test_helper"

class CrmRepurchaseFollowUpsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin  = User.create!(email: "crmadm@test.com", username: "crmadmin", password: "password123", role: admin_role)
    @nobody = User.create!(email: "crmnobody@test.com", username: "crmnobody", password: "password123")

    @cycle = CrmCustomerProductCycle.create!(
      identity_key: "ctrl_test_#{SecureRandom.hex(4)}",
      email: "ctrltest@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 3,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 3, 2),
      suggested_contact_date: Date.new(2026, 2, 23),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    )
  end

  test "index renders for an authorized (admin) user" do
    sign_in @admin
    get crm_repurchase_dashboard_path

    assert_response :success
    assert_includes response.body, "回購追蹤"
  end

  test "index is blocked for a user without page permission" do
    sign_in @nobody
    get crm_repurchase_dashboard_path

    assert_redirected_to root_path
  end

  test "update applies a follow-up action and redirects" do
    sign_in @admin
    patch crm_repurchase_follow_up_path(@cycle), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply", note: "測試備註" }
    }

    assert_response :redirect
    assert_equal "waiting_reply", @cycle.reload.follow_up_status
  end

  test "update creates a follow_up_event history row" do
    sign_in @admin
    assert_difference -> { @cycle.follow_up_events.count }, 1 do
      patch crm_repurchase_follow_up_path(@cycle), params: {
        follow_up: { follow_up_action: "contacted_waiting_reply" }
      }
    end

    event = @cycle.follow_up_events.last
    assert_equal @admin.id, event.performed_by_user_id
  end

  test "update is blocked for a user without page permission" do
    sign_in @nobody
    patch crm_repurchase_follow_up_path(@cycle), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply" }
    }

    assert_response :forbidden
    assert_nil @cycle.reload.follow_up_status
  end

  test "update is blocked entirely when not signed in" do
    patch crm_repurchase_follow_up_path(@cycle), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply" }
    }

    assert_response :redirect
    assert_nil @cycle.reload.follow_up_status
  end

  test "strong parameters ignore unpermitted keys (e.g. cannot set match_status directly)" do
    sign_in @admin
    patch crm_repurchase_follow_up_path(@cycle), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply", match_status: "same_product_repurchase" }
    }

    assert_equal "not_yet_repurchased", @cycle.reload.match_status
  end

  test "invalid action redirects with an alert and does not create a history event" do
    sign_in @admin
    assert_no_difference -> { @cycle.follow_up_events.count } do
      patch crm_repurchase_follow_up_path(@cycle), params: {
        follow_up: { follow_up_action: "rescheduled" } # missing required next_contact_date
      }
    end

    assert_response :redirect
    assert flash[:alert].present?
  end

  test "index does not issue a per-row ShoplineCustomer query (batched IN, not N+1)" do
    20.times do |i|
      CrmCustomerProductCycle.create!(
        identity_key: "n1_#{i}_#{SecureRandom.hex(4)}",
        email: "n1_#{i}_#{SecureRandom.hex(4)}@example.com",
        product_key: "omnipotent",
        cycle_started_at: Date.new(2026, 1, 1),
        bottle_count: 1,
        estimated_usage_days: 30,
        estimated_finish_date: Date.new(2026, 2, 1),
        suggested_contact_date: Date.new(2026, 1, 25),
        match_status: "not_yet_repurchased",
        refreshed_at: Time.current
      )
    end

    sign_in @admin
    # 先觸發一次 schema introspection（pg_attribute 查詢只在 process 內第一次
    # 使用該 model 時發生一次），避免跟下面真正要量測的資料查詢混在一起算。
    ShoplineCustomer.columns

    customer_queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      customer_queries << payload[:sql] if payload[:sql] =~ /SELECT.*FROM "shopline_customers"/
    end
    get crm_repurchase_dashboard_path
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_response :success
    assert_operator customer_queries.size, :<=, 1,
      "expected ShoplineCustomer lookups to be batched into one IN query, got: #{customer_queries.size}"
  end
end
