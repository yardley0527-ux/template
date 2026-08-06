# frozen_string_literal: true

require "test_helper"

class CrmLivestreamOutreachSchedulerTest < ActiveSupport::TestCase
  LIVESTREAM_DATE = Date.new(2026, 9, 1) # 週二
  SCHEDULE_DATE    = Date.new(2026, 8, 17) # 直播前，週一，單日排程測試用

  def unique_key
    "sched_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label, medians: { 1 => 60 })
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    medians.each { |bottles, days| CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: bottles, median_days: days, source: "manual") }
  end

  def make_livestream(product_keys, date: LIVESTREAM_DATE)
    Livestream.create!(date: date, title: "排程測試直播 #{SecureRandom.hex(4)}", product_keys: product_keys)
  end

  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "sched_#{SecureRandom.hex(4)}",
      email: "sched_#{SecureRandom.hex(4)}@example.com",
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

  def actor
    users(:one)
  end

  test "預覽不寫入資料庫" do
    key = unique_key
    make_product(key, "測試A")
    livestream = make_livestream([key])
    3.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    assert_no_difference -> { CrmLivestreamOutreachTask.count } do
      CrmLivestreamOutreachScheduler.preview(
        livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false
      )
    end
  end

  test "commit! 才會真正建立任務" do
    key = unique_key
    make_product(key, "測試B")
    livestream = make_livestream([key])
    2.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    assert_difference -> { CrmLivestreamOutreachTask.count }, 2 do
      CrmLivestreamOutreachScheduler.commit!(
        livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false, actor: actor
      )
    end
  end

  test "每位客服每天不超過設定上限" do
    key = unique_key
    make_product(key, "測試C")
    livestream = make_livestream([key])
    5.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    plan = CrmLivestreamOutreachScheduler.preview(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
      user_ids: [actor.id], daily_cap: 2, exclude_saturday: false, exclude_sunday: false
    )

    assert_equal 2, plan.scheduled_count
    assert_equal 3, plan.unscheduled_count
    assert_equal 2, plan.daily_breakdown[SCHEDULE_DATE][actor.id][:scheduled]
  end

  test "排除設定的週末" do
    key = unique_key
    make_product(key, "測試D")
    livestream = make_livestream([key])
    # 2026/08/17(一) ~ 2026/08/21(五)：08/22(六)、08/23(日) 已經不在範圍內，
    # 改用一個確實橫跨週末的範圍：08/17(一) ~ 08/24(一)
    10.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    plan = CrmLivestreamOutreachScheduler.preview(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE + 7,
      user_ids: [actor.id], daily_cap: 100, exclude_saturday: true, exclude_sunday: true
    )

    scheduled_dates = plan.assignments.map { |a| a[:date] }.uniq.sort
    assert_not_includes scheduled_dates, Date.new(2026, 8, 22) # 週六
    assert_not_includes scheduled_dates, Date.new(2026, 8, 23) # 週日
    assert_equal 6, plan.gross_capacity / 100 # 08/17~08/24 扣掉六日剩 6 個工作天 * 100 上限
  end

  test "產能不足時只安排優先順序較高的候選人" do
    key = unique_key
    make_product(key, "測試E")
    livestream = make_livestream([key])

    high_priority = build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE + 3) # replenish，最高優先
    low_priority  = build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 70) # win_back_61_90，較低優先

    plan = CrmLivestreamOutreachScheduler.preview(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
      user_ids: [actor.id], daily_cap: 1, exclude_saturday: false, exclude_sunday: false
    )

    assert_equal 1, plan.scheduled_count
    assigned_identity_key = plan.assignments.first[:cycle].identity_key
    assert_equal high_priority.identity_key, assigned_identity_key
    assert_not_equal low_priority.identity_key, assigned_identity_key
  end

  test "排序 deterministic：同樣資料重跑預覽結果不漂移" do
    key = unique_key
    make_product(key, "測試F")
    livestream = make_livestream([key])
    10.times { |i| build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10 - i) }

    args = { livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
             user_ids: [actor.id], daily_cap: 5, exclude_saturday: false, exclude_sunday: false }

    order1 = CrmLivestreamOutreachScheduler.preview(**args).assignments.map { |a| a[:cycle].identity_key }
    order2 = CrmLivestreamOutreachScheduler.preview(**args).assignments.map { |a| a[:cycle].identity_key }
    order3 = CrmLivestreamOutreachScheduler.preview(**args).assignments.map { |a| a[:cycle].identity_key }

    assert_equal order1, order2
    assert_equal order2, order3
  end

  test "同一顧客命中多產品只建立一筆顧客層級任務，且保存所有命中產品與原因" do
    key_a = unique_key
    key_b = unique_key
    make_product(key_a, "測試G甲")
    make_product(key_b, "測試G乙")
    livestream = make_livestream([key_a, key_b])

    identity_key = "multi_#{SecureRandom.hex(4)}"
    # 直播後 3 天用完：在 replenish 的 ±14 天窗內，但還沒逾期（不會同時命中 win_back）。
    build_cycle(identity_key: identity_key, product_key: key_a, estimated_finish_date: LIVESTREAM_DATE + 3)
    # 直播前 20 天用完：在 win_back_1_30 範圍內，但落在 replenish 的 ±14 天窗外，避免
    # 同一產品同時命中兩個原因（那是合法情境，但這裡要測的是「兩個不同產品各一個 hit」）。
    build_cycle(identity_key: identity_key, product_key: key_b, estimated_finish_date: LIVESTREAM_DATE - 20)

    CrmLivestreamOutreachScheduler.commit!(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
      user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false, actor: actor
    )

    tasks = CrmLivestreamOutreachTask.where(livestream_id: livestream.id, identity_key: identity_key)
    assert_equal 1, tasks.count
    hit_product_keys = tasks.first.hit_summary.map { |h| h["product_key"] }
    assert_equal [key_a, key_b].sort, hit_product_keys.sort
  end

  test "同一場直播重複建立排程不會重複建立任務" do
    key = unique_key
    make_product(key, "測試H")
    livestream = make_livestream([key])
    3.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    args = { livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
             user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false, actor: actor }

    CrmLivestreamOutreachScheduler.commit!(**args)
    assert_no_difference -> { CrmLivestreamOutreachTask.count } do
      CrmLivestreamOutreachScheduler.commit!(**args)
    end
  end

  test "已完成任務不可被 reschedule! 覆寫" do
    key = unique_key
    make_product(key, "測試I")
    livestream = make_livestream([key])
    cycle = build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10)

    CrmLivestreamOutreachScheduler.commit!(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
      user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false, actor: actor
    )
    task = CrmLivestreamOutreachTask.find_by(identity_key: cycle.identity_key)
    task.complete!

    assert_raises(CrmLivestreamOutreachScheduler::InvalidScheduleError) do
      CrmLivestreamOutreachScheduler.reschedule!(task: task, new_date: SCHEDULE_DATE + 5, new_assigned_to_user_id: users(:two).id)
    end
  end

  test "已存在的未完成任務會占用當日產能（跨直播共用同一位客服的每日上限）" do
    key = unique_key
    make_product(key, "測試J")
    other_livestream = make_livestream([key], date: SCHEDULE_DATE - 30)
    livestream = make_livestream([key])

    # 先在別的直播排一筆任務給同一位客服、同一天
    pre_existing_cycle = build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 5)
    CrmLivestreamOutreachTask.create!(
      livestream: other_livestream, cycle: pre_existing_cycle, identity_key: pre_existing_cycle.identity_key,
      assigned_to_user_id: actor.id, scheduled_date: SCHEDULE_DATE, status: "pending",
      candidate_reason: "win_back_1_30", hit_summary: [], created_by: actor
    )

    3.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    plan = CrmLivestreamOutreachScheduler.preview(
      livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
      user_ids: [actor.id], daily_cap: 2, exclude_saturday: false, exclude_sunday: false
    )

    # 毛產能 2（1 客服 * 上限2 * 1天），既有任務占用 1，淨可用 1
    assert_equal 2, plan.gross_capacity
    assert_equal 1, plan.occupied_capacity
    assert_equal 1, plan.available_capacity
    assert_equal 1, plan.scheduled_count
    assert_equal plan.gross_capacity - plan.occupied_capacity, plan.available_capacity
    assert_operator plan.scheduled_count, :<=, plan.available_capacity

    cell = plan.daily_breakdown[SCHEDULE_DATE][actor.id]
    assert_equal 2, cell[:cap]
    assert_equal 1, cell[:existing]
    assert_equal 1, cell[:available]
    assert_equal 1, cell[:scheduled]
  end

  # ── Phase 4.1：日期規則 ─────────────────────────────────────────

  test "start_date 晚於直播日期會被拒絕" do
    key = unique_key
    make_product(key, "測試K")
    livestream = make_livestream([key])

    assert_raises(CrmLivestreamOutreachScheduler::InvalidScheduleError) do
      CrmLivestreamOutreachScheduler.preview(
        livestream: livestream, start_date: LIVESTREAM_DATE + 1, end_date: LIVESTREAM_DATE + 1,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false
      )
    end
  end

  test "end_date 晚於直播前一天（且未允許當日聯絡）會被拒絕" do
    key = unique_key
    make_product(key, "測試L")
    livestream = make_livestream([key])

    assert_raises(CrmLivestreamOutreachScheduler::InvalidScheduleError) do
      CrmLivestreamOutreachScheduler.preview(
        livestream: livestream, start_date: SCHEDULE_DATE, end_date: LIVESTREAM_DATE,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false,
        allow_same_day_contact: false
      )
    end
  end

  test "明確允許直播當日聯絡時，end_date 可以等於直播日期" do
    key = unique_key
    make_product(key, "測試M")
    livestream = make_livestream([key])
    build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10)

    plan = CrmLivestreamOutreachScheduler.preview(
      livestream: livestream, start_date: LIVESTREAM_DATE, end_date: LIVESTREAM_DATE,
      user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false,
      allow_same_day_contact: true
    )

    assert_equal [LIVESTREAM_DATE], plan.daily_breakdown.keys
  end

  test "end_date 早於 start_date 會被拒絕" do
    key = unique_key
    make_product(key, "測試N")
    livestream = make_livestream([key])

    assert_raises(CrmLivestreamOutreachScheduler::InvalidScheduleError) do
      CrmLivestreamOutreachScheduler.preview(
        livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE - 1,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false
      )
    end
  end

  test "歷史直播（已經結束）不能建立直播前排程" do
    key = unique_key
    make_product(key, "測試O")
    past_livestream = make_livestream([key], date: Date.current - 10)

    assert_raises(CrmLivestreamOutreachScheduler::InvalidScheduleError) do
      CrmLivestreamOutreachScheduler.preview(
        livestream: past_livestream, start_date: Date.current - 10, end_date: Date.current - 10,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false
      )
    end
  end

  test "預設結束日是直播前一天，預設開始日是直播前14天（若不早於今天）" do
    livestream = make_livestream([unique_key])

    assert_equal LIVESTREAM_DATE - 1, CrmLivestreamOutreachScheduler.default_end_date(livestream)

    far_future_livestream = make_livestream([unique_key], date: Date.current + 60)
    assert_equal (Date.current + 60) - 14, CrmLivestreamOutreachScheduler.default_start_date(far_future_livestream)
  end

  test "直播前14天若落在過去，預設開始日改為今天" do
    near_livestream = make_livestream([unique_key], date: Date.current + 3)
    assert_equal Date.current, CrmLivestreamOutreachScheduler.default_start_date(near_livestream)
  end

  # Phase 5：缺週期設定的產品（冰晶番茄情境）混在直播 product_keys 裡，排程
  # 不能因為 nil 出錯，也不會幫這個產品生出候選人或任務。
  test "缺週期設定的產品混在 product_keys 裡不會讓排程出錯，也不會產生它的任務" do
    configured_key = unique_key
    unconfigured_key = unique_key
    make_product(configured_key, "測試辰")
    CrmProduct.create!(key: unconfigured_key, label: "測試巳（無週期）", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試巳（無週期）%'") # 刻意不建立 CrmRepurchaseCycleConfig
    livestream = make_livestream([configured_key, unconfigured_key])

    build_cycle(product_key: configured_key, estimated_finish_date: SCHEDULE_DATE - 10)
    # 無週期設定的產品即使有訂單，也不會有 cycle（builder 端已經處理），這裡確保排程不因此出錯。

    plan = nil
    assert_nothing_raised do
      plan = CrmLivestreamOutreachScheduler.preview(
        livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
        user_ids: [actor.id], daily_cap: 10, exclude_saturday: false, exclude_sunday: false
      )
    end

    assert_equal 1, plan.eligible_count
    assert_equal [configured_key], plan.assignments.map { |a| a[:cycle].product_key }.uniq
  end

  # ── Phase 4.1 第五節：完整走一次「預覽 → 確認 → 重複確認」驗證 ──────
  test "完整驗證：預覽不寫入、確認寫入 scheduled_count 筆、內容與預覽一致、重複確認不新增、已完成任務不被覆寫" do
    key = unique_key
    make_product(key, "測試P")
    livestream = make_livestream([key])
    5.times { build_cycle(product_key: key, estimated_finish_date: SCHEDULE_DATE - 10) }

    args = { livestream: livestream, start_date: SCHEDULE_DATE, end_date: SCHEDULE_DATE,
             user_ids: [actor.id], daily_cap: 3, exclude_saturday: false, exclude_sunday: false }

    # 1. 預覽後新增任務數 = 0
    preview_plan = nil
    assert_no_difference -> { CrmLivestreamOutreachTask.count } do
      preview_plan = CrmLivestreamOutreachScheduler.preview(**args)
    end
    assert_equal 3, preview_plan.scheduled_count

    # 2. 確認後新增任務數 = scheduled_count
    commit_plan = nil
    assert_difference -> { CrmLivestreamOutreachTask.count }, preview_plan.scheduled_count do
      commit_plan = CrmLivestreamOutreachScheduler.commit!(**args, actor: actor)
    end

    # 4. 已建立任務內容與預覽一致（同一批候選、同一套 deterministic 排序，
    #    兩次呼叫的 build_plan 輸入沒變，結果必須一致）
    assert_equal preview_plan.assignments.map { |a| a[:cycle].identity_key }.sort,
                 commit_plan.assignments.map { |a| a[:cycle].identity_key }.sort

    commit_plan.assignments.each do |a|
      task = CrmLivestreamOutreachTask.find_by(livestream_id: livestream.id, identity_key: a[:cycle].identity_key)
      assert task.present?
      assert_equal a[:user_id], task.assigned_to_user_id
      assert_equal a[:date], task.scheduled_date
      assert_equal a[:reason], task.candidate_reason
    end

    # 3. 同樣參數再次確認，新增任務數 = 0
    assert_no_difference -> { CrmLivestreamOutreachTask.count } do
      CrmLivestreamOutreachScheduler.commit!(**args, actor: actor)
    end

    # 5. 已完成任務不被第二次確認修改
    completed_task = CrmLivestreamOutreachTask.where(livestream_id: livestream.id).first
    completed_task.complete!
    original_attributes = completed_task.reload.attributes

    CrmLivestreamOutreachScheduler.commit!(**args, actor: actor)

    assert_equal original_attributes, completed_task.reload.attributes
  end
end
