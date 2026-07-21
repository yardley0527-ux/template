# frozen_string_literal: true

require "test_helper"

class IgDiscountCohortLookupTest < ActiveSupport::TestCase
  test "the committed YAML file contains no PII fields" do
    raw = File.read(IgDiscountCohortLookup::YAML_PATH)
    assert_no_match(/name:/, raw)
    assert_no_match(/email:/, raw)
    assert_no_match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/, raw, "YAML 不得含 email")
    assert_no_match(/09\d{2}-?\d{3}-?\d{3}/, raw, "YAML 不得含台灣手機號碼")
  end

  test "entries are sourced from the existing pre-committed controller constant, not duplicated PII" do
    entries = IgDiscountCohortLookup.entries
    assert_equal 29, entries.size
    assert entries.all? { |e| e.key?("name") && e.key?("email") }, "資料仍應完整可用（來自既有常數），只是不重複存進新的 YAML"
  end

  test "metadata fields are present" do
    assert_equal Date.new(2026, 6, 5), IgDiscountCohortLookup.event_date
    assert_equal Date.new(2026, 10, 8), IgDiscountCohortLookup.review_date
    assert IgDiscountCohortLookup.source.present?
    assert IgDiscountCohortLookup.purpose.present?
  end
end
