# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class LivestreamPreparationTest < ActiveSupport::TestCase
    test "no card at T-3 when no livestream event is scheduled that day" do
      assert_empty LivestreamPreparation.call
    end

    test "T-3 with nothing set up yet produces a P2 card listing every missing item" do
      CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: 3.days.from_now.to_date)

      result = LivestreamPreparation.call.find { |r| r[:notification_key] == "livestream_preparation_t3" }
      assert result.present?
      assert_equal "P2", result[:priority]
      assert_includes result[:metadata][:missing_items], "featured_products"
      assert_includes result[:metadata][:missing_items], "owner_assigned"
    end

    test "T-1 with missing items is at least P1" do
      CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: 1.day.from_now.to_date)

      result = LivestreamPreparation.call.find { |r| r[:notification_key] == "livestream_preparation_t1" }
      assert_equal "P1", result[:priority]
    end

    test "no card when every checked item is complete" do
      CrmProduct.create!(key: "collagen", label: "膠原蛋白", status: "confirmed", availability_status: "in_stock")
      u = User.create!(username: "owner1", email: "owner1@example.com", password: "password123")
      event = CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: 3.days.from_now.to_date)
      livestream = Livestream.create!(date: event.event_date, product_keys: ["collagen"], owner_user_id: u.id)
      livestream.livestream_products.create!(name: "膠原蛋白（6盒）", price: 17600)
      cycle = CrmCustomerProductCycle.create!(
        identity_key: "a@example.com", email: "a@example.com", product_key: "collagen",
        cycle_started_at: 40.days.ago.to_date, bottle_count: 1, estimated_usage_days: 30,
        estimated_finish_date: 10.days.ago.to_date, suggested_contact_date: 5.days.ago.to_date,
        match_status: "not_yet_repurchased", refreshed_at: Time.current
      )
      CrmLivestreamOutreachTask.create!(
        livestream: livestream, cycle: cycle, identity_key: cycle.identity_key,
        assigned_to: u, created_by: u, scheduled_date: Date.current, status: "pending",
        candidate_reason: "replenish"
      )

      assert_empty LivestreamPreparation.call
    end

    test "products_purchasable is false when a featured product is out of stock" do
      CrmProduct.create!(key: "collagen", label: "膠原蛋白", status: "confirmed", availability_status: "out_of_stock")
      event = CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: 3.days.from_now.to_date)
      Livestream.create!(date: event.event_date, product_keys: ["collagen"])

      result = LivestreamPreparation.call.find { |r| r[:notification_key] == "livestream_preparation_t3" }
      assert_includes result[:metadata][:missing_items], "products_purchasable"
    end
  end
end
