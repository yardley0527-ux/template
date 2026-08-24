# frozen_string_literal: true

require "test_helper"

class NotificationCustomerTaskServiceTest < ActiveSupport::TestCase
  def cycle(email:, product_key: "metabolism", follow_up_status: nil)
    CrmCustomerProductCycle.create!(
      identity_key: email, email: email, product_key: product_key,
      cycle_started_at: 40.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: 10.days.ago.to_date, suggested_contact_date: 5.days.ago.to_date,
      match_status: "not_yet_repurchased", follow_up_status: follow_up_status, refreshed_at: Time.current
    )
  end

  def notification(product_key: "metabolism")
    Notification.create!(
      notification_key: "test", kind: "opportunity", category: "customer_overdue", severity: "opportunity",
      priority: "P2", title: "t", deduplication_key: "test:#{SecureRandom.hex(4)}", status: "detected",
      first_detected_at: Time.current, last_detected_at: Time.current,
      metadata: { "query" => { "product_key" => product_key } }
    )
  end

  def actor
    User.create!(username: "csr#{SecureRandom.hex(3)}", email: "csr#{SecureRandom.hex(3)}@example.com", password: "password123")
  end

  test "creates a follow-up on the matching open cycle" do
    c = cycle(email: "a@example.com")
    result = NotificationCustomerTaskService.call(notification: notification, emails: ["a@example.com"], actor: actor)

    assert_equal 1, result.created
    assert_equal "rescheduled", c.reload.follow_up_status
  end

  test "skips a customer who already has an active (non-repurchased) follow-up status" do
    cycle(email: "a@example.com", follow_up_status: "waiting_reply")
    result = NotificationCustomerTaskService.call(notification: notification, emails: ["a@example.com"], actor: actor)

    assert_equal 0, result.created
    assert_equal 1, result.skipped
  end

  test "does not skip a customer whose cycle already repurchased (that is a closed loop, not an active task)" do
    cycle(email: "a@example.com", follow_up_status: "repurchased")
    result = NotificationCustomerTaskService.call(notification: notification, emails: ["a@example.com"], actor: actor)

    assert_equal 1, result.created
  end

  test "counts emails with no matching cycle as no_cycle rather than silently dropping them" do
    result = NotificationCustomerTaskService.call(notification: notification, emails: ["nobody@example.com"], actor: actor)
    assert_equal 1, result.no_cycle
    assert_equal 0, result.created
  end

  test "sets the assignee when given" do
    cycle(email: "a@example.com")
    u = actor
    NotificationCustomerTaskService.call(notification: notification, emails: ["a@example.com"], actor: actor, assigned_to_user_id: u.id)
    assert_equal u.id, CrmCustomerProductCycle.find_by(email: "a@example.com").assigned_to_user_id
  end

  test "creates a CrmCustomerProductFollowUpEvent as the immutable history record" do
    cycle(email: "a@example.com")
    assert_difference "CrmCustomerProductFollowUpEvent.count", 1 do
      NotificationCustomerTaskService.call(notification: notification, emails: ["a@example.com"], actor: actor)
    end
  end
end
