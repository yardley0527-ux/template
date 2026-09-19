# frozen_string_literal: true

require_relative "group_buy_crm_view_test_helper"

class GroupBuyCrmMembersTest < ActiveSupport::TestCase
  include GroupBuyCrmViewTestHelper

  def member_row(customer) = Member.find(customer.id)

  test "there is exactly one row per shopline_customer, even with several profiles" do
    a = build_customer(shopline_id: "GBP1", email: "gb.p1@example.com")
    2.times { CustomerProfile.create!(shopline_customer_id: a.id, blacklisted: false) }
    build_customer(shopline_id: "GBP2", email: nil)

    assert_equal ShoplineCustomer.count, Member.count
    assert_equal Member.count, Member.pluck(:shopline_customer_id).uniq.size
  end

  test "blacklisted = shopline blacklisted OR any profile blacklisted, NULL counts as false, no source exposed" do
    cases = {
      "GBB1" => { shopline: nil,   profiles: [],             expected: false },
      "GBB2" => { shopline: false, profiles: [false],        expected: false },
      "GBB3" => { shopline: true,  profiles: [],             expected: true  },
      "GBB4" => { shopline: nil,   profiles: [true],         expected: true  },
      "GBB5" => { shopline: false, profiles: [false, true],  expected: true  }, # one of several profiles
      "GBB6" => { shopline: true,  profiles: [false, false], expected: true  }
    }
    cases.each do |shopline_id, spec|
      customer = build_customer(shopline_id: shopline_id, email: "#{shopline_id.downcase}@example.com", blacklisted: spec[:shopline])
      spec[:profiles].each { |b| CustomerProfile.create!(shopline_customer_id: customer.id, blacklisted: b) }
      assert_equal spec[:expected], member_row(customer).blacklisted, shopline_id
      assert_includes [true, false], member_row(customer).blacklisted, "never NULL"
    end
  end

  test "a NULL membership level and a NULL total_amount are passed through untouched (no defaulting)" do
    c = build_customer(shopline_id: "GBL1", email: "gb.l1@example.com", membership_level: nil, total_amount: nil)
    row = member_row(c)
    assert_nil row.membership_level
    assert_nil row.total_amount
  end

  test "levels, total_amount, credits, points, expiry and join date come straight from shopline_customers" do
    c = build_customer(shopline_id: "GBL2", email: "gb.l2@example.com", membership_level: "金卡", total_amount: 12_345.5,
                       current_shopping_credits: 120, current_points: 33, membership_expiry_date: Date.new(2027, 1, 31),
                       joined_at: Time.utc(2025, 3, 4, 5))
    row = member_row(c)
    assert_equal "金卡", row.membership_level
    assert_equal BigDecimal("12345.5"), row.total_amount
    assert_equal BigDecimal("120"), row.credits
    assert_equal 33, row.points
    assert_equal Date.new(2027, 1, 31), row.membership_expiry_date
    assert_equal Time.utc(2025, 3, 4, 5), row.joined_at.utc
  end

  test "normalized_email uses the shared rule, and is NULL when there is no usable email" do
    messy = build_customer(shopline_id: "GBE1", email: "　 GB.Mixed​@Example.COM 　")
    none  = build_customer(shopline_id: "GBE2", email: nil)
    blank = build_customer(shopline_id: "GBE3", email: "   　 ")
    gmail = build_customer(shopline_id: "GBE4", email: "First.Last+Tag@Gmail.com")

    assert_equal "gb.mixed@example.com", member_row(messy).normalized_email
    assert_nil member_row(none).normalized_email
    assert_nil member_row(blank).normalized_email
    assert_equal "first.last+tag@gmail.com", member_row(gmail).normalized_email, "gmail dots and plus tags are kept"
    assert_equal "　 GB.Mixed​@Example.COM 　", member_row(messy).email, "the raw email is exposed unchanged"
  end

  test "last_order_date is the newest counted order (unpaid and unattributed orders do not count)" do
    c = build_customer(shopline_id: "GBO1", email: "gb.o1@example.com")
    build_order(order_number: "GB-LO1", product_name: "薑黃3", customer: c, order_date: Time.utc(2026, 2, 1, 4))
    build_order(order_number: "GB-LO2", product_name: "薑黃3", customer: c, order_date: Time.utc(2026, 6, 1, 4))
    build_order(order_number: "GB-LO3", product_name: "薑黃3", customer: c, order_date: Time.utc(2026, 9, 1, 4), payment_status: "未付款")
    never = build_customer(shopline_id: "GBO2", email: "gb.o2@example.com")

    assert_equal Time.utc(2026, 6, 1, 4), member_row(c).last_order_date.utc
    assert_nil member_row(never).last_order_date
  end

  test "looking a member up by normalized email finds exactly the matching rows" do
    build_customer(shopline_id: "GBQ1", email: "Gb.Q1@Example.com")
    build_customer(shopline_id: "GBQ2", email: "gb.q2@example.com")

    assert_equal ["GBQ1"], Member.where(normalized_email: "gb.q1@example.com").pluck(:shopline_id)
    assert_empty Member.where(normalized_email: "gb.q3@example.com")
  end

  test "the read-only models refuse writes" do
    c = build_customer(shopline_id: "GBW1", email: "gb.w1@example.com")
    assert_raises(ActiveRecord::ReadOnlyRecord) { member_row(c).update!(name: "changed") }
  end
end
