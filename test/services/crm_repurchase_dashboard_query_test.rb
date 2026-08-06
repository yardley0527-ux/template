# frozen_string_literal: true

require "test_helper"

class CrmRepurchaseDashboardQueryTest < ActiveSupport::TestCase
  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "test_#{SecureRandom.hex(4)}",
      email: "test_#{SecureRandom.hex(4)}@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 3,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 3, 2),
      suggested_contact_date: Date.new(2026, 2, 23),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    }.merge(overrides))
  end

  test "KPI 數字跟用同一狀態篩選列表得到的 total_count 一致" do
    travel_to Date.new(2026, 3, 1) do
      3.times { build_cycle(estimated_finish_date: Date.new(2026, 2, 20)) } # overdue
      2.times { build_cycle(estimated_finish_date: Date.new(2026, 3, 1)) }  # due_today
      4.times { build_cycle(estimated_finish_date: Date.new(2026, 3, 5)) }  # due_soon
      1.times { build_cycle(follow_up_status: "waiting_reply") }

      query = CrmRepurchaseDashboardQuery.new({}, reference_date: Date.current)
      kpis  = query.kpis

      assert_equal kpis[:overdue],       CrmRepurchaseDashboardQuery.new({ status: "overdue" },       reference_date: Date.current).total_count
      assert_equal kpis[:due_today],     CrmRepurchaseDashboardQuery.new({ status: "due_today" },     reference_date: Date.current).total_count
      assert_equal kpis[:due_soon],      CrmRepurchaseDashboardQuery.new({ status: "due_soon" },      reference_date: Date.current).total_count
      assert_equal kpis[:waiting_reply], CrmRepurchaseDashboardQuery.new({ status: "waiting_reply" }, reference_date: Date.current).total_count

      assert_equal 3, kpis[:overdue]
      assert_equal 2, kpis[:due_today]
      assert_equal 4, kpis[:due_soon]
      assert_equal 1, kpis[:waiting_reply]
    end
  end

  test "repurchased_this_month 計算的是 next_same_product_order_date 落在本月的 cycle，跟 active 狀態無關" do
    travel_to Date.new(2026, 3, 15) do
      build_cycle(match_status: "same_product_repurchase", next_same_product_order_date: Date.new(2026, 3, 10))
      build_cycle(match_status: "same_product_repurchase", next_same_product_order_date: Date.new(2026, 2, 28)) # 上個月，不算
      build_cycle # 沒回購，不算

      kpis = CrmRepurchaseDashboardQuery.new({}, reference_date: Date.current).kpis
      assert_equal 1, kpis[:repurchased_this_month]
    end
  end

  test "product_key 篩選只回傳指定產品" do
    a = build_cycle(product_key: "omnipotent")
    b = build_cycle(product_key: "metabolism", identity_key: "b_#{SecureRandom.hex(4)}")

    ids = CrmRepurchaseDashboardQuery.new({ product_key: "metabolism" }).cycles.map(&:id)
    assert_includes ids, b.id
    assert_not_includes ids, a.id
  end

  test "assigned_to 篩選只回傳指定負責人" do
    u = users(:one)
    assigned = build_cycle(assigned_to_user_id: u.id)
    unassigned = build_cycle(identity_key: "unassigned_#{SecureRandom.hex(4)}")

    ids = CrmRepurchaseDashboardQuery.new({ assigned_to: u.id.to_s }).cycles.map(&:id)
    assert_includes ids, assigned.id
    assert_not_includes ids, unassigned.id
  end

  test "顧客搜尋可以用 email 或姓名找到" do
    target_email = "findme_#{SecureRandom.hex(4)}@example.com"
    ShoplineCustomer.create!(email: target_email, full_name: "測試搜尋顧客")
    cycle = build_cycle(email: target_email)
    other = build_cycle

    by_email = CrmRepurchaseDashboardQuery.new({ q: target_email }).cycles.map(&:id)
    assert_includes by_email, cycle.id
    assert_not_includes by_email, other.id

    by_name = CrmRepurchaseDashboardQuery.new({ q: "測試搜尋顧客" }).cycles.map(&:id)
    assert_includes by_name, cycle.id
  end

  test "分頁：PER_PAGE 邊界與 total_pages 計算正確" do
    (CrmRepurchaseDashboardQuery::PER_PAGE + 5).times { build_cycle }

    query = CrmRepurchaseDashboardQuery.new({})
    assert_equal CrmRepurchaseDashboardQuery::PER_PAGE, query.cycles.size
    assert_equal 2, query.total_pages

    page2 = CrmRepurchaseDashboardQuery.new({ page: "2" })
    assert_equal 5, page2.cycles.size
  end

  test "預設排序：今日已逾期 → 今日待聯絡 → 7天內即將用完 → 其他追蹤中" do
    travel_to Date.new(2026, 3, 1) do
      tracking  = build_cycle(estimated_finish_date: Date.new(2026, 5, 1))
      due_soon  = build_cycle(estimated_finish_date: Date.new(2026, 3, 5))
      due_today = build_cycle(estimated_finish_date: Date.new(2026, 3, 1))
      overdue   = build_cycle(estimated_finish_date: Date.new(2026, 2, 20))

      ordered_ids = CrmRepurchaseDashboardQuery.new({}, reference_date: Date.current).cycles.map(&:id)
      expected_order = [overdue.id, due_today.id, due_soon.id, tracking.id]
      assert_equal expected_order, ordered_ids & expected_order
    end
  end
end
