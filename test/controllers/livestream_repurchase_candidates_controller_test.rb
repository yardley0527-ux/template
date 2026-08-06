# frozen_string_literal: true

require "test_helper"

class LivestreamRepurchaseCandidatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin  = User.create!(email: "lsadm@test.com", username: "lsadmin", password: "password123", role: admin_role)
    @nobody = User.create!(email: "lsnobody@test.com", username: "lsnobody", password: "password123")

    @key = "ls_ctrl_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: @key, label: "測試控制器品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試控制器品%'", regex_pattern: "測試控制器品(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: @key, bottle_count: 1, median_days: 60, source: "manual")

    @livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "控制器測試直播", product_keys: [@key])

    @cycle = CrmCustomerProductCycle.create!(
      identity_key: "ls_ctrl_cycle_#{SecureRandom.hex(4)}",
      email: "lsctrl@example.com",
      product_key: @key,
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 1,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 5, 1),
      suggested_contact_date: Date.new(2026, 4, 24),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    )
  end

  test "index without livestream_id shows the picker only" do
    sign_in @admin
    get livestream_repurchase_candidates_path

    assert_response :success
    assert_includes response.body, "請先選擇"
  end

  test "index with livestream_id shows KPIs and the candidate for an authorized user" do
    sign_in @admin
    get livestream_repurchase_candidates_path(livestream_id: @livestream.id)

    assert_response :success
    assert_includes response.body, "補貨客"
    assert_includes response.body, @cycle.email
  end

  test "index is blocked for a user without page permission" do
    sign_in @nobody
    get livestream_repurchase_candidates_path(livestream_id: @livestream.id)

    assert_redirected_to root_path
  end

  test "update reuses CrmCustomerProductCycleFollowUpService and records livestream_id on the history event" do
    sign_in @admin
    patch livestream_repurchase_candidate_path(livestream_id: @livestream.id, cycle_id: @cycle.id), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply", note: "直播名單聯絡" }
    }

    assert_response :redirect
    @cycle.reload
    assert_equal "waiting_reply", @cycle.follow_up_status

    event = @cycle.follow_up_events.last
    assert_equal @livestream.id, event.livestream_id
    assert_equal "直播名單聯絡", event.note
  end

  test "update is blocked for a user without page permission" do
    sign_in @nobody
    patch livestream_repurchase_candidate_path(livestream_id: @livestream.id, cycle_id: @cycle.id), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply" }
    }

    assert_response :forbidden
    assert_nil @cycle.reload.follow_up_status
  end

  test "a follow-up event created from the repurchase dashboard (no livestream) has a nil livestream_id" do
    sign_in @admin
    patch crm_repurchase_follow_up_path(@cycle), params: {
      follow_up: { follow_up_action: "contacted_waiting_reply" }
    }

    event = @cycle.reload.follow_up_events.last
    assert_nil event.livestream_id
  end
end
