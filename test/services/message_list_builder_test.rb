# frozen_string_literal: true

require "test_helper"

class MessageListBuilderTest < ActiveSupport::TestCase
  def make_customer(email:, ig: nil, name: nil, blacklisted: false, brand_blacklisted: false)
    c = ShoplineCustomer.create!(shopline_id: SecureRandom.hex(12), email: email, instagram_account: ig, full_name: name)
    if blacklisted || brand_blacklisted
      CustomerProfile.create!(shopline_customer_id: c.id, blacklisted: blacklisted, brand_ambassador_blacklisted: brand_blacklisted)
    end
    c
  end

  def build(emails, note: "原始口徑")
    MessageListBuilder.create!(name: "測試名單", sent_on: Date.current, target_product: "全能", emails: emails, source_note: note)
  end

  test "excludes brand-ambassador and general blacklisted customers and records them in source_note" do
    make_customer(email: "ok@example.com")
    make_customer(email: "brand@example.com", name: "大使黑", brand_blacklisted: true)
    make_customer(email: "black@example.com", name: "一般黑", blacklisted: true)

    list = build(%w[ok@example.com Brand@Example.com black@example.com])

    assert_equal ["ok@example.com"], list.recipients.pluck(:email)
    assert_includes list.source_note, "原始口徑"
    assert_includes list.source_note, "已排除黑名單 2 人"
    assert_includes list.source_note, "大使黑"
  end

  test "excludes other accounts of a blacklisted customer sharing the same IG" do
    make_customer(email: "main@example.com", ig: "SameIG", name: "多帳號", brand_blacklisted: true)
    make_customer(email: "alt@example.com", ig: "sameig", name: "多帳號")
    make_customer(email: "ok@example.com")

    list = build(%w[alt@example.com ok@example.com])

    assert_equal ["ok@example.com"], list.recipients.pluck(:email)
  end

  test "placeholder IG like 無 does not spread the blacklist to unrelated customers" do
    make_customer(email: "black@example.com", ig: "無", blacklisted: true)
    make_customer(email: "other@example.com", ig: "無")

    list = build(%w[other@example.com])

    assert_equal ["other@example.com"], list.recipients.pluck(:email)
    assert_equal "原始口徑", list.source_note
  end

  test "returns nil and creates nothing when everyone is blacklisted" do
    make_customer(email: "black@example.com", blacklisted: true)

    assert_no_difference "MessageList.count" do
      assert_nil build(%w[black@example.com])
    end
  end
end
