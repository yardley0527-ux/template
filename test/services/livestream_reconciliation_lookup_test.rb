# frozen_string_literal: true

require "test_helper"

class LivestreamReconciliationLookupTest < ActiveSupport::TestCase
  test "returns unmapped_products for a known backfilled date" do
    result = LivestreamReconciliationLookup.unmapped_products_for(Date.parse("2024-12-23"))
    assert_equal ["酵素"], result
  end

  test "returns empty array for a date not present in the YAML (not an error)" do
    assert_equal [], LivestreamReconciliationLookup.unmapped_products_for(Date.new(2099, 1, 1))
  end

  test "returns empty array for a date with no unmapped products" do
    assert_equal [], LivestreamReconciliationLookup.unmapped_products_for(Date.parse("2026-06-05"))
  end
end
