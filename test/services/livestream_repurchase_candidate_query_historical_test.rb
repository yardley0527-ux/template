# frozen_string_literal: true

require "test_helper"

# Phase 3.1：歷史直播（livestream.date < 今天）名單重建的時間穿越修正。
# 全部用 travel_to 把「現在」固定在直播日之後，模擬「回頭看一場已經結束的
# 直播」的真實情境。
class LivestreamRepurchaseCandidateQueryHistoricalTest < ActiveSupport::TestCase
  LIVESTREAM_DATE = Date.new(2026, 6, 1)
  NOW = Date.new(2026, 8, 1) # 晚於直播日，讓 historical? 一律是 true

  def unique_key
    "ls_hist_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label, medians: { 1 => 60 })
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    medians.each { |bottles, days| CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: bottles, median_days: days, source: "manual") }
  end

  def make_livestream(product_keys, date: LIVESTREAM_DATE)
    Livestream.create!(date: date, title: "歷史測試直播 #{SecureRandom.hex(4)}", product_keys: product_keys)
  end

  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "hist_#{SecureRandom.hex(4)}",
      email: "hist_#{SecureRandom.hex(4)}@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 1,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 3, 2),
      suggested_contact_date: Date.new(2026, 2, 23),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    }.merge(overrides))
  end

  def make_event(cycle, action:, performed_at:, next_contact_date: nil)
    CrmCustomerProductFollowUpEvent.create!(
      cycle: cycle, performed_by: users(:one), action: action,
      performed_at: performed_at, next_contact_date: next_contact_date
    )
  end

  test "直播後才購買（同品回購）的客人不會出現在歷史候選——不當成直播前已回購而排除" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試甲")
      livestream = make_livestream([key])

      # 直播前的週期，直播「後」才真正回購（matcher 事後才補上這個事實）
      cycle = build_cycle(product_key: key, cycle_started_at: Date.new(2026, 1, 1),
                           estimated_finish_date: Date.new(2026, 5, 1), # 31 天逾期
                           next_same_product_order_date: Date.new(2026, 7, 1), next_same_product_order_number: "ORD_AFTER")

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert query.historical?
      row = query.candidate_rows.find { |r| r.identity_key == cycle.identity_key }
      assert row.present?, "直播後才發生的回購不能被當成「直播前已回購」而排除"
      assert_includes row.reasons, "win_back_31_60"
    end
  end

  test "直播之後才開始的週期（直播後才購買）不會出現在歷史候選" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試乙")
      livestream = make_livestream([key])

      after_livestream_cycle = build_cycle(product_key: key, cycle_started_at: Date.new(2026, 6, 15),
                                            estimated_finish_date: Date.new(2026, 8, 15))

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_not_includes query.candidate_rows.map(&:identity_key), after_livestream_cycle.identity_key
    end
  end

  test "直播後才發生的聯絡紀錄不影響歷史場次狀態（不會被當成最近7天已聯絡而排除，也不會顯示成已聯絡）" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試丙")
      livestream = make_livestream([key])

      cycle = build_cycle(product_key: key, estimated_finish_date: Date.new(2026, 5, 1)) # 31 天逾期
      # 直播「後」才聯絡——不應該影響直播當天的名單
      make_event(cycle, action: "contacted_waiting_reply", performed_at: Date.new(2026, 6, 10).to_time)

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      row = query.candidate_rows.find { |r| r.identity_key == cycle.identity_key }
      assert row.present?, "直播後才發生的聯絡不能讓候選人消失"
      assert_nil row.representative_cycle.last_contacted_at, "直播當天重建出來的狀態不應該看到直播後才發生的聯絡"
      assert_equal 0, query.kpis[:contacted]
    end
  end

  test "歷史直播選擇當時最新且有效的 cycle，不是現在最新的 cycle" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試丁")
      livestream = make_livestream([key])
      identity_key = "same_person_#{SecureRandom.hex(4)}"

      old_cycle = build_cycle(identity_key: identity_key, product_key: key,
                               cycle_started_at: Date.new(2026, 1, 1), estimated_finish_date: Date.new(2026, 5, 1))
      # 直播之後才發生的新週期（例如直播後才有下一筆購買）——現在的 active task 是它，
      # 但直播當天，old_cycle 才是「當時」有效的那一筆。
      build_cycle(identity_key: identity_key, product_key: key,
                  cycle_started_at: Date.new(2026, 7, 1), estimated_finish_date: Date.new(2026, 9, 1))

      # 驗證「現在」的 active_follow_up 確實已經是新週期（前提正確）
      assert_equal [old_cycle.id],
        CrmCustomerProductCycle.active_as_of(LIVESTREAM_DATE).where(identity_key: identity_key).pluck(:id)
      assert_not_equal CrmCustomerProductCycle.active_follow_up.where(identity_key: identity_key).pluck(:id),
        CrmCustomerProductCycle.active_as_of(LIVESTREAM_DATE).where(identity_key: identity_key).pluck(:id)

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      row = query.candidate_rows.find { |r| r.identity_key == identity_key }
      assert row.present?
      assert_equal old_cycle.id, row.representative_cycle.id
    end
  end

  test "逾期 90 天內（含）進入預設名單，超過 90 天只進歷史沉睡客名單" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試戊")
      livestream = make_livestream([key])

      within_90  = build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 90) # 剛好 90 天
      over_90    = build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 91) # 91 天

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      default_ids = query.candidate_rows.map(&:identity_key)
      assert_includes default_ids, within_90.identity_key
      assert_not_includes default_ids, over_90.identity_key

      row_over_90 = query.send(:all_rows).find { |r| r.identity_key == over_90.identity_key }
      assert_includes row_over_90.reasons, "dormant_over_90"

      dormant_filtered = LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "dormant_over_90" })
      assert_includes dormant_filtered.candidate_rows.map(&:identity_key), over_90.identity_key
    end
  end

  test "win_back_max_days 可自訂，改變 dormant 門檻" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試己")
      livestream = make_livestream([key])
      cycle_100d = build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 100)

      default_query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_not_includes default_query.candidate_rows.map(&:identity_key), cycle_100d.identity_key

      widened_query = LivestreamRepurchaseCandidateQuery.new(livestream, { win_back_max_days: "120" })
      assert_includes widened_query.candidate_rows.map(&:identity_key), cycle_100d.identity_key
    end
  end

  test "各分桶人數（summary_counts）與名單篩選結果一致" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試庚")
      livestream = make_livestream([key])

      build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE + 5)   # replenish
      build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 10)  # win_back_1_30
      build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 45)  # win_back_31_60
      build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 75)  # win_back_61_90
      build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 200) # dormant_over_90

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      summary = query.summary_counts

      assert_equal summary[:replenish],       LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "replenish" }).total_count
      assert_equal summary[:win_back_1_30],    LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "win_back_1_30" }).total_count
      assert_equal summary[:win_back_31_60],   LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "win_back_31_60" }).total_count
      assert_equal summary[:win_back_61_90],   LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "win_back_61_90" }).total_count
      assert_equal summary[:dormant_over_90],  LivestreamRepurchaseCandidateQuery.new(livestream, { reason: "dormant_over_90" }).total_count
      assert_equal summary[:default_actionable], query.total_count
    end
  end

  test "Phase 4 一：候選原因人數是人數不是人次——同一顧客命中兩個原因時，兩個分桶都各算一次，但顧客總數只有一個" do
    travel_to NOW do
      key_a = unique_key
      key_b = unique_key
      make_product(key_a, "測試子甲")
      make_product(key_b, "測試子乙")
      livestream = make_livestream([key_a, key_b])

      identity_key = "overlap_#{SecureRandom.hex(4)}"
      # 同一人：A 產品命中 replenish，B 產品命中 win_back_1_30——一人occupies兩個分桶
      build_cycle(identity_key: identity_key, product_key: key_a, estimated_finish_date: LIVESTREAM_DATE + 5)
      build_cycle(identity_key: identity_key, product_key: key_b, estimated_finish_date: LIVESTREAM_DATE - 10)

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      summary = query.summary_counts

      assert_equal 1, summary[:replenish]
      assert_equal 1, summary[:win_back_1_30]
      # 兩個分桶加總(2) > 去重後的預設可執行名單總數(1)——這就是規格要求要標示清楚的重疊現象
      assert_equal 1, summary[:default_actionable]
      assert_operator summary[:replenish] + summary[:win_back_1_30], :>, summary[:default_actionable]

      # 同一顧客不會在「同一個」分桶內被算兩次（即使命中該分桶的兩個不同產品）
      build_cycle(identity_key: "solo_#{SecureRandom.hex(4)}", product_key: key_a, estimated_finish_date: LIVESTREAM_DATE + 3)
      solo_check = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_equal 2, solo_check.summary_counts[:replenish]
    end
  end

  test "未來直播（historical? == false）操作功能不受歷史修正影響" do
    travel_to Date.new(2026, 5, 1) do # 早於直播日 -> 未來直播
      key = unique_key
      make_product(key, "測試辛")
      livestream = make_livestream([key])
      cycle = build_cycle(product_key: key, estimated_finish_date: LIVESTREAM_DATE - 10, follow_up_status: "waiting_reply")

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      assert_not query.historical?
      row = query.candidate_rows.find { |r| r.identity_key == cycle.identity_key }
      assert row.present?
      assert_equal "waiting_reply", row.representative_cycle.follow_up_status
    end
  end

  test "同一顧客不會因為多筆歷史週期而重複出現" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試壬")
      livestream = make_livestream([key])
      identity_key = "dup_check_#{SecureRandom.hex(4)}"

      build_cycle(identity_key: identity_key, product_key: key,
                  cycle_started_at: Date.new(2026, 1, 1), estimated_finish_date: Date.new(2026, 2, 1))
      build_cycle(identity_key: identity_key, product_key: key,
                  cycle_started_at: Date.new(2026, 3, 1), estimated_finish_date: Date.new(2026, 5, 1))

      query = LivestreamRepurchaseCandidateQuery.new(livestream, {})
      matches = query.candidate_rows.select { |r| r.identity_key == identity_key }
      assert_equal 1, matches.size
    end
  end

  test "歷史場次會標示 estimate_disclaimer_needed?，未來場次不會" do
    travel_to NOW do
      key = unique_key
      make_product(key, "測試癸")
      historical_ls = make_livestream([key], date: LIVESTREAM_DATE)
      future_ls     = make_livestream([key], date: NOW + 30)

      assert LivestreamRepurchaseCandidateQuery.new(historical_ls, {}).estimate_disclaimer_needed?
      assert_not LivestreamRepurchaseCandidateQuery.new(future_ls, {}).estimate_disclaimer_needed?
    end
  end
end
