# frozen_string_literal: true

require "test_helper"

# 這個檔案測試「未來／今天」的直播（historical? == false）——用 travel_to
# 把「現在」固定在直播日之前，直接沿用即時的 cycle 欄位（follow_up_status/
# last_contacted_at 等），驗證 Phase 2/3 既有行為不受 Phase 3.1 影響。
# 歷史重建（historical? == true）的規則另外在
# livestream_repurchase_candidate_query_historical_test.rb 測試。
class LivestreamRepurchaseCandidateQueryTest < ActiveSupport::TestCase
  NOW = Date.new(2026, 5, 25) # 早於下面所有測試用的直播日期，確保 historical? 一律是 false

  def unique_key
    "ls_cand_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label, medians: { 1 => 60 })
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    medians.each { |bottles, days| CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: bottles, median_days: days, source: "manual") }
  end

  def make_livestream(date, product_keys)
    Livestream.create!(date: date, title: "測試直播 #{SecureRandom.hex(4)}", product_keys: product_keys)
  end

  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "cand_#{SecureRandom.hex(4)}",
      email: "cand_#{SecureRandom.hex(4)}@example.com",
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

  test "直播日前後 14 天內用完的顧客被標記為 replenish" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試A")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      inside  = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 6, 10))
      edge    = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 6, 15))
      outside = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 7, 1))

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_not query.historical?
      ids_with_replenish = query.candidate_rows.select { |r| r.reasons.include?("replenish") }.map(&:identity_key)

      assert_includes ids_with_replenish, inside.identity_key
      assert_includes ids_with_replenish, edge.identity_key
      assert_not_includes ids_with_replenish, outside.identity_key
    end
  end

  test "已逾期未回購的顧客被標記為對應的 win_back 分桶" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試B")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      overdue_31d = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1)) # 31 天
      not_overdue = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 12, 1))

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      row = query.candidate_rows.find { |r| r.identity_key == overdue_31d.identity_key }
      assert row.present?
      assert_includes row.reasons, "win_back_31_60"

      assert_not_includes query.candidate_rows.map(&:identity_key), not_overdue.identity_key
    end
  end

  test "最近 7 天已聯絡者被排除" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試C")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      recently_contacted = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1), last_contacted_at: Date.new(2026, 6, 1) - 2.days)
      long_ago_contacted  = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1), last_contacted_at: Date.new(2026, 6, 1) - 30.days)

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      ids = query.candidate_rows.map(&:identity_key)

      assert_not_includes ids, recently_contacted.identity_key
      assert_includes ids, long_ago_contacted.identity_key
    end
  end

  test "paused 被排除" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試D")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      paused = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1), follow_up_status: "paused")

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_not_includes query.candidate_rows.map(&:identity_key), paused.identity_key
    end
  end

  test "已人工標記 repurchased 與系統已偵測同品回購都被排除" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試E")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      manually_repurchased = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1), follow_up_status: "repurchased")
      system_detected       = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1),
                                           next_same_product_order_date: Date.new(2026, 5, 20), next_same_product_order_number: "ORD1")

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      ids = query.candidate_rows.map(&:identity_key)
      assert_not_includes ids, manually_repurchased.identity_key
      assert_not_includes ids, system_detected.identity_key
    end
  end

  test "缺週期設定的產品被排除，且可在 products_missing_cycle_config 計數" do
    travel_to NOW do
      key = unique_key
      CrmProduct.create!(key: key, label: "測試缺週期品", status: "confirmed", sql_pattern: "product_name LIKE '%測試缺週期品%'")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_equal 0, query.total_count
      missing = query.products_missing_cycle_config
      assert_equal [key], missing.map { |m| m[:product_key] }
    end
  end

  test "多產品直播：同一顧客命中兩個產品，名單只顯示一列，並列出多個命中產品與原因" do
    travel_to NOW do
      key_a = unique_key
      key_b = unique_key
      make_product(key_a, "測試F甲")
      make_product(key_b, "測試F乙")
      livestream = make_livestream(Date.new(2026, 6, 1), [key_a, key_b])

      identity_key = "shared_#{SecureRandom.hex(4)}"
      build_cycle(identity_key: identity_key, product_key: key_a, estimated_finish_date: Date.new(2026, 6, 5))  # replenish
      build_cycle(identity_key: identity_key, product_key: key_b, estimated_finish_date: Date.new(2026, 4, 1))  # 61 天逾期 -> win_back_61_90

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      rows = query.candidate_rows.select { |r| r.identity_key == identity_key }
      assert_equal 1, rows.size, "同一顧客在直播總名單只能出現一列"

      row = rows.first
      assert_equal [key_a, key_b].sort, row.hit_product_keys.sort
      assert_includes row.reasons, "replenish"
      assert_includes row.reasons, "win_back_61_90"
    end
  end

  test "not_yet_handled KPI 只算沒有人工狀態的候選人，且範圍跟預設可執行名單一致" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試H")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])
      build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1)) # 未處理
      build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1), follow_up_status: "waiting_reply")

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_equal 1, query.kpis[:not_yet_handled]
      assert_equal 1, query.kpis[:waiting_reply]
      assert_equal query.summary_counts[:default_actionable], query.total_count
    end
  end

  test "候選原因／產品／狀態篩選都正確" do
    travel_to NOW do
      key_a = unique_key
      key_b = unique_key
      make_product(key_a, "測試I甲")
      make_product(key_b, "測試I乙")
      livestream = make_livestream(Date.new(2026, 6, 1), [key_a, key_b])

      replenish_a = build_cycle(product_key: key_a, estimated_finish_date: Date.new(2026, 6, 10))
      winback_b   = build_cycle(product_key: key_b, estimated_finish_date: Date.new(2026, 5, 1)) # 31 天 -> win_back_31_60

      reason_filtered = LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "win_back_31_60" })
      assert_includes reason_filtered.candidate_rows.map(&:identity_key), winback_b.identity_key
      assert_not_includes reason_filtered.candidate_rows.map(&:identity_key), replenish_a.identity_key

      product_filtered = LivestreamRepurchaseCandidateQuery.new(livestream, { product_key: key_a })
      assert_includes product_filtered.candidate_rows.map(&:identity_key), replenish_a.identity_key
      assert_not_includes product_filtered.candidate_rows.map(&:identity_key), winback_b.identity_key
    end
  end

  test "分頁：PER_PAGE 邊界正確" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試J")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])
      (LivestreamRepurchaseCandidateQuery::PER_PAGE + 3).times { build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1)) }

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_equal LivestreamRepurchaseCandidateQuery::PER_PAGE, query.page_rows.size
      assert_equal 2, query.total_pages

      page2 = LivestreamRepurchaseCandidateQuery.new(livestream, { page: "2" })
      assert_equal 3, page2.page_rows.size
    end
  end

  test "只需一條 SQL 取得候選 cycle，不隨候選人數逐列查詢（無 N+1）" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試K")
      livestream = make_livestream(Date.new(2026, 6, 1), [key])
      30.times { build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1)) }

      query_count = 0
      counter = ->(*, payload) { query_count += 1 if payload[:sql] =~ /\ASELECT.*crm_customer_product_cycles/i }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        LivestreamRepurchaseCandidateQuery.new(livestream, {}).candidate_rows
      end

      assert_equal 1, query_count, "候選 cycle 應該只需要一條 SQL"
    end
  end
end
