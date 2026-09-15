# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingTodoTargetResolverTest < ActiveSupport::TestCase
  test "unresolved for a blank or unknown type" do
    assert_equal false, WeeklyBriefingTodoTargetResolver.call(nil)[:resolved]
    assert_equal false, WeeklyBriefingTodoTargetResolver.call({})[:resolved]
    assert_equal false, WeeklyBriefingTodoTargetResolver.call({ "type" => "made_up" })[:resolved]
  end

  test "product_overdue is unresolved when the product_key does not exist" do
    result = WeeklyBriefingTodoTargetResolver.call({ "type" => "product_overdue", "product_key" => "nope", "min_days" => 1 })
    assert_equal false, result[:resolved]
  end

  test "product_overdue resolves to the emails currently overdue for that product" do
    key = "resolver_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "解析測試品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%解析測試品%'", regex_pattern: "解析測試品(\\d+)")

    CrmCustomerProductCycle.create!(
      identity_key: "overdue@example.com", email: "overdue@example.com", product_key: key,
      cycle_started_at: Date.current - 100, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: Date.current - 70, suggested_contact_date: Date.current - 70,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
    CrmCustomerProductCycle.create!(
      identity_key: "fine@example.com", email: "fine@example.com", product_key: key,
      cycle_started_at: Date.current - 5, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: Date.current + 25, suggested_contact_date: Date.current + 25,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )

    result = WeeklyBriefingTodoTargetResolver.call({ "type" => "product_overdue", "product_key" => key, "min_days" => 1 })

    assert result[:resolved]
    assert_equal 1, result[:count]
    assert_equal ["overdue@example.com"], result[:emails]
  end

  test "dormant_member resolves emails at that level whose last order predates the silent window" do
    ShoplineCustomer.create!(email: "dormant@example.com", membership_level: "金卡", full_name: "沉睡")
    ShoplineCustomer.create!(email: "active@example.com", membership_level: "金卡", full_name: "活躍")
    CustomerPurchaseSummary.create!(identity_key: "id1", email: "dormant@example.com", first_date: Date.current - 300,
                                     last_order_date: Date.current - 120, purchase_count: 2,
                                     silent_only: false, silent_days_threshold: 45)
    CustomerPurchaseSummary.create!(identity_key: "id2", email: "active@example.com", first_date: Date.current - 300,
                                     last_order_date: Date.current - 5, purchase_count: 2,
                                     silent_only: false, silent_days_threshold: 45)

    result = WeeklyBriefingTodoTargetResolver.call({ "type" => "dormant_member", "level" => "金卡", "min_silent_days" => 90 })

    assert result[:resolved]
    assert_equal ["dormant@example.com"], result[:emails]
  end

  test "dormant_member is unresolved for an invalid level" do
    result = WeeklyBriefingTodoTargetResolver.call({ "type" => "dormant_member", "level" => "不存在卡" })
    assert_equal false, result[:resolved]
  end
end
