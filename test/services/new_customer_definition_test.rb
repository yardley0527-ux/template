# frozen_string_literal: true

require "test_helper"

class NewCustomerDefinitionTest < ActiveSupport::TestCase
  test "new_in_period? is true only when first_purchase_date falls within the period" do
    assert NewCustomerDefinition.new_in_period?(Date.new(2026, 6, 15), Date.new(2026, 6, 15), Date.new(2026, 6, 21))
    assert_not NewCustomerDefinition.new_in_period?(Date.new(2026, 6, 1), Date.new(2026, 6, 15), Date.new(2026, 6, 21))
    assert_not NewCustomerDefinition.new_in_period?(nil, Date.new(2026, 6, 15), Date.new(2026, 6, 21))
  end

  test "first_purchase_dates takes the earliest first_date when an email has more than one summary row" do
    CustomerPurchaseSummary.create!(identity_key: "k1", email: "dup@example.com", first_date: Date.new(2026, 3, 1),
                                     purchase_count: 1, silent_only: false, silent_days_threshold: 45)
    CustomerPurchaseSummary.create!(identity_key: "k2", email: "dup@example.com", first_date: Date.new(2026, 1, 1),
                                     purchase_count: 1, silent_only: false, silent_days_threshold: 45)

    result = NewCustomerDefinition.first_purchase_dates(["dup@example.com"])
    assert_equal Date.new(2026, 1, 1), result["dup@example.com"]
  end

  test "returns an empty hash for blank input without querying" do
    assert_equal({}, NewCustomerDefinition.first_purchase_dates([]))
    assert_equal({}, NewCustomerDefinition.first_purchase_dates([nil, ""]))
  end
end
