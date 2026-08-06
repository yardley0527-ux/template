# frozen_string_literal: true

require "test_helper"

class CrmOutreachTasksControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    staff_role = Role.create!(key: "ot_staff", name: "Outreach Staff")
    PagePermission.create!(role: staff_role, controller_name: "crm_outreach_tasks")

    @admin = User.create!(email: "otadm@test.com", username: "otadmin", password: "password123", role: admin_role)
    @csr_a = User.create!(email: "otcsra@test.com", username: "otcsra", password: "password123", role: staff_role)
    @csr_b = User.create!(email: "otcsrb@test.com", username: "otcsrb", password: "password123", role: staff_role)

    @key = "ot_ctrl_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: @key, label: "測試控制器品OT", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試控制器品OT%'", regex_pattern: "測試控制器品OT(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: @key, bottle_count: 1, median_days: 60, source: "manual")
    @livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "控制器測試", product_keys: [@key])

    @cycle_a = build_cycle(email: "csra_customer@example.com")
    @cycle_b = build_cycle(email: "csrb_customer@example.com")

    @task_a = build_task(@cycle_a, @csr_a)
    @task_b = build_task(@cycle_b, @csr_b)
  end

  def build_cycle(email:)
    CrmCustomerProductCycle.create!(
      identity_key: "ot_ctrl_#{SecureRandom.hex(4)}", email: email, product_key: @key,
      cycle_started_at: Date.new(2026, 1, 1), bottle_count: 1, estimated_usage_days: 60,
      estimated_finish_date: Date.current, suggested_contact_date: Date.current - 7,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
  end

  def build_task(cycle, assignee)
    CrmLivestreamOutreachTask.create!(
      livestream: @livestream, cycle: cycle, identity_key: cycle.identity_key,
      assigned_to_user_id: assignee.id, scheduled_date: Date.current, status: "pending",
      candidate_reason: "win_back_1_30", hit_summary: [{ product_key: @key, reason: "win_back_1_30" }],
      created_by: assignee
    )
  end

  test "客服只能看到分派給自己的任務" do
    sign_in @csr_a
    get crm_outreach_tasks_path(bucket: "all_pending")

    assert_response :success
    assert_includes response.body, @cycle_a.email
    assert_not_includes response.body, @cycle_b.email
  end

  test "管理者可以查看全部客服的任務" do
    sign_in @admin
    get crm_outreach_tasks_path(bucket: "all_pending")

    assert_response :success
    assert_includes response.body, @cycle_a.email
    assert_includes response.body, @cycle_b.email
  end

  test "客服不能操作別人的任務" do
    sign_in @csr_a
    patch crm_outreach_task_path(@task_b), params: { follow_up: { follow_up_action: "contacted_waiting_reply" } }

    assert_response :forbidden
    assert_equal "pending", @task_b.reload.status
  end

  test "客服可以操作自己的任務，且會建立 follow_up_event" do
    sign_in @csr_a
    assert_difference -> { @cycle_a.follow_up_events.count }, 1 do
      patch crm_outreach_task_path(@task_a), params: { follow_up: { follow_up_action: "contacted_waiting_reply" } }
    end

    assert_equal "completed", @task_a.reload.status
  end

  test "只有管理者可以重新排程" do
    sign_in @csr_a
    patch reschedule_crm_outreach_task_path(@task_a), params: { scheduled_date: Date.current + 3, assigned_to_user_id: @csr_b.id }

    assert_response :forbidden
  end

  test "管理者可以重新排程未完成任務" do
    sign_in @admin
    new_date = Date.current + 3
    patch reschedule_crm_outreach_task_path(@task_a), params: { scheduled_date: new_date, assigned_to_user_id: @csr_b.id }

    assert_response :redirect
    @task_a.reload
    assert_equal new_date, @task_a.scheduled_date
    assert_equal @csr_b.id, @task_a.assigned_to_user_id
  end

  test "重新排程會用 PaperTrail 記錄操作者（Phase 5：先前漏了 set_paper_trail_whodunnit）" do
    sign_in @admin
    patch reschedule_crm_outreach_task_path(@task_a), params: { scheduled_date: Date.current + 3, assigned_to_user_id: @csr_b.id }

    version = @task_a.versions.last
    assert version.present?
    assert_equal @admin.id.to_s, version.whodunnit
  end

  test "已完成任務不能被重新排程" do
    @task_a.complete!
    sign_in @admin
    patch reschedule_crm_outreach_task_path(@task_a), params: { scheduled_date: Date.current + 3, assigned_to_user_id: @csr_b.id }

    assert_response :redirect
    assert flash[:alert].present?
  end

  test "index 不會對每列各查一次 ShoplineCustomer（無 N+1）" do
    10.times do
      cycle = build_cycle(email: "n1_#{SecureRandom.hex(4)}@example.com")
      build_task(cycle, @admin)
    end

    sign_in @admin
    ShoplineCustomer.columns # 先觸發一次 process 內的 schema introspection，避免混進量測
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql] =~ /SELECT.*FROM "shopline_customers"/
    end
    get crm_outreach_tasks_path(bucket: "all_pending")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_response :success
    assert_operator queries.size, :<=, 1
  end
end
