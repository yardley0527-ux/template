# frozen_string_literal: true

# 把一場直播的候選名單（LivestreamRepurchaseCandidateQuery 的預設可執行名單，
# 不含歷史沉睡客）排進客服每日產能。分兩步：
#   .preview  —— 純計算，不寫 DB
#   .commit!  —— 重新跑一次一模一樣的 deterministic 計算，才落地建立任務
#
# 兩步都呼叫同一個 #build_plan，不會有「預覽看到一種結果、確認後建立另一種
# 結果」的落差，除非底層候選/既有任務資料在兩次請求之間真的變了（候選 query
# 本來就是即時計算，這是預期行為，不是 bug）。
#
# Phase 4.1：這裡建立的是「直播前候選邀請排程」——預設只能排在直播日期以前
# （或直播當天，需管理者明確勾選 allow_same_day_contact）。直播結束後的
# 追蹤排程是不同的功能，還沒開發；日期晚於允許範圍會直接拒絕並提示。
class CrmLivestreamOutreachScheduler
  class InvalidScheduleError < StandardError; end

  DEFAULT_LOOKBACK_DAYS = 14

  Plan = Struct.new(
    :eligible_count,
    :gross_capacity,      # 毛產能：user_ids.size × daily_cap × 工作天數，不考慮既有任務
    :occupied_capacity,   # 已被跨直播既有未完成任務占用的產能
    :available_capacity,  # 淨可用產能 = gross_capacity - occupied_capacity
    :scheduled_count,     # 本次實際安排人數（<= available_capacity）
    :unscheduled_count,   # 因產能不足未安排人數
    :daily_breakdown,     # { date => { user_id => { cap:, existing:, available:, scheduled: } } }
    :reason_breakdown,
    :assignments,
    keyword_init: true
  )

  REASON_ORDER = %w[replenish win_back_1_30 win_back_31_60 win_back_61_90].freeze

  def self.preview(livestream:, start_date:, end_date:, user_ids:, daily_cap:, exclude_saturday:, exclude_sunday:, allow_same_day_contact: false)
    new(livestream: livestream, start_date: start_date, end_date: end_date, user_ids: user_ids,
        daily_cap: daily_cap, exclude_saturday: exclude_saturday, exclude_sunday: exclude_sunday,
        allow_same_day_contact: allow_same_day_contact).build_plan
  end

  def self.commit!(livestream:, start_date:, end_date:, user_ids:, daily_cap:, exclude_saturday:, exclude_sunday:, actor:, allow_same_day_contact: false)
    scheduler = new(livestream: livestream, start_date: start_date, end_date: end_date, user_ids: user_ids,
                     daily_cap: daily_cap, exclude_saturday: exclude_saturday, exclude_sunday: exclude_sunday,
                     allow_same_day_contact: allow_same_day_contact)
    plan = scheduler.build_plan

    ActiveRecord::Base.transaction do
      plan.assignments.each do |a|
        CrmLivestreamOutreachTask.create!(
          livestream:            livestream,
          cycle:                 a[:cycle],
          identity_key:          a[:cycle].identity_key,
          assigned_to_user_id:   a[:user_id],
          scheduled_date:        a[:date],
          status:                "pending",
          candidate_reason:      a[:reason],
          hit_summary:           a[:hit_summary],
          created_by:            actor
        )
      end
    end

    plan
  end

  # 明確的重新排程操作（不是 delete_all 重建）：只能改未完成任務的日期／負責人，
  # 已完成任務不可被覆寫；PaperTrail（CrmLivestreamOutreachTask#has_paper_trail）
  # 記錄變更歷史。
  def self.reschedule!(task:, new_date:, new_assigned_to_user_id:)
    raise InvalidScheduleError, "completed task cannot be rescheduled" if task.status == "completed"

    task.update!(scheduled_date: new_date, assigned_to_user_id: new_assigned_to_user_id)
    task
  end

  # ── 表單預設值（Phase 4.1）───────────────────────────────────────
  # end_date 預設直播前一天；start_date 預設直播前 14 天，但不早於今天
  # （直播前 14 天如果已經是過去，排程只能從今天開始排，不能排過去的日期）。
  def self.default_start_date(livestream, reference_date: Date.current)
    candidate = livestream.date - DEFAULT_LOOKBACK_DAYS
    candidate < reference_date ? reference_date : candidate
  end

  def self.default_end_date(livestream)
    livestream.date - 1
  end

  def initialize(livestream:, start_date:, end_date:, user_ids:, daily_cap:, exclude_saturday:, exclude_sunday:, allow_same_day_contact: false)
    @livestream             = livestream
    @start_date             = start_date
    @end_date               = end_date
    @user_ids               = user_ids.map(&:to_i).uniq.sort # 固定排序，deterministic
    @daily_cap              = daily_cap.to_i
    @exclude_saturday       = ActiveModel::Type::Boolean.new.cast(exclude_saturday)
    @exclude_sunday         = ActiveModel::Type::Boolean.new.cast(exclude_sunday)
    @allow_same_day_contact = ActiveModel::Type::Boolean.new.cast(allow_same_day_contact)

    validate!
  end

  def build_plan
    gross      = @user_ids.size * working_days.size * @daily_cap
    occupied   = occupied_capacity
    available  = gross - occupied

    slots       = build_slot_sequence
    candidates  = eligible_sorted_candidates
    assignments = assign(candidates, slots)

    Plan.new(
      eligible_count:      candidates.size,
      gross_capacity:      gross,
      occupied_capacity:   occupied,
      available_capacity:  available,
      scheduled_count:     assignments.size,
      unscheduled_count:   candidates.size - assignments.size,
      daily_breakdown:     daily_breakdown_for(assignments),
      reason_breakdown:    reason_breakdown_for(assignments),
      assignments:         assignments
    )
  end

  private

  def validate!
    raise InvalidScheduleError, "daily_cap must be positive" unless @daily_cap.positive?
    raise InvalidScheduleError, "at least one user is required" if @user_ids.empty?
    raise InvalidScheduleError, "end_date must be on or after start_date" if @end_date < @start_date

    if @livestream.date < Date.current
      raise InvalidScheduleError, "歷史直播（#{@livestream.date}）已經結束，不能建立直播前邀請排程"
    end

    if @start_date > @livestream.date
      raise InvalidScheduleError, "排程開始日不得晚於直播日期（#{@livestream.date}）"
    end

    latest_allowed_end = @allow_same_day_contact ? @livestream.date : @livestream.date - 1
    if @end_date > latest_allowed_end
      raise InvalidScheduleError,
        "排程結束日不得晚於#{@allow_same_day_contact ? '直播當天' : '直播前一天'}" \
        "（#{latest_allowed_end}）。直播後的追蹤排程是另一個尚未開發的功能，不是這裡的用途。"
    end
  end

  def working_days
    @working_days ||= (@start_date..@end_date).select { |d| working_day?(d) }
  end

  def working_day?(date)
    return false if @exclude_saturday && date.saturday?
    return false if @exclude_sunday && date.sunday?

    true
  end

  # 既有（任何直播）未完成任務對每位客服每天的產能占用——一位客服的每日產能
  # 是跨直播共用的真實限制，不是只看這場直播。
  def existing_incomplete_counts
    @existing_incomplete_counts ||= CrmLivestreamOutreachTask
      .where(assigned_to_user_id: @user_ids, scheduled_date: working_days, status: "pending")
      .group(:assigned_to_user_id, :scheduled_date)
      .count
  end

  # 每個 (user, date) 被既有任務占用的產能，最多占到 daily_cap（不會出現負的
  # available）。gross_capacity - occupied_capacity 才會等於實際可用的 slot 數。
  def occupied_capacity
    working_days.sum do |date|
      @user_ids.sum { |user_id| [existing_incomplete_counts[[user_id, date]] || 0, @daily_cap].min }
    end
  end

  # 日期在最外層：先把最早的日子填滿（輪流分給每位客服到各自上限），優先順序
  # 較高的候選人才會被排進最早的日期——deterministic，同樣輸入重跑順序完全相同。
  def build_slot_sequence
    slots = []
    working_days.each do |date|
      (1..@daily_cap).each do |round|
        @user_ids.each do |user_id|
          used = existing_incomplete_counts[[user_id, date]] || 0
          slots << { date: date, user_id: user_id } if round <= (@daily_cap - used)
        end
      end
    end
    slots
  end

  def assign(candidates, slots)
    slots = slots.dup
    assignments = []

    candidates.each do |row|
      slot = slots.shift
      break unless slot

      reason = row.reasons.select { |r| REASON_ORDER.include?(r) }.min_by { |r| REASON_ORDER.index(r) }
      assignments << {
        row: row, cycle: row.representative_cycle, user_id: slot[:user_id], date: slot[:date],
        reason: reason,
        hit_summary: row.hits.map { |h| { product_key: h[:product_key], reason: h[:reason] } }
      }
    end

    assignments
  end

  # 管理者要能看懂「某一天為什麼沒排滿」：每位客服每天的上限、既有任務數、
  # 扣掉既有任務後還能新增幾筆、這次實際排了幾筆。
  def daily_breakdown_for(assignments)
    scheduled_counts = assignments.group_by { |a| a[:date] }
      .transform_values { |as| as.group_by { |a| a[:user_id] }.transform_values(&:size) }

    working_days.index_with do |date|
      @user_ids.index_with do |user_id|
        existing   = existing_incomplete_counts[[user_id, date]] || 0
        capped_existing = [existing, @daily_cap].min
        {
          cap:        @daily_cap,
          existing:    existing,
          available:   @daily_cap - capped_existing,
          scheduled:   scheduled_counts.dig(date, user_id) || 0
        }
      end
    end
  end

  def reason_breakdown_for(assignments)
    assignments.group_by { |a| a[:reason] }.transform_values(&:size)
  end

  # 已經在這場直播有任務（不管完成與否）的顧客整批排除——不重複建立既有任務，
  # 也不會靜默改動未完成任務的負責人/日期（那要走明確的 reschedule!）。
  def eligible_sorted_candidates
    already_scheduled = CrmLivestreamOutreachTask.where(livestream_id: @livestream.id).pluck(:identity_key).to_set

    query = LivestreamRepurchaseCandidateQuery.new(@livestream, {})
    rows = query.candidate_rows.reject { |r| already_scheduled.include?(r.identity_key) }

    customers = customers_by_email(rows)

    rows.sort_by do |r|
      c = customers[r.representative_cycle.email]
      [
        r.best_reason_priority,
        r.remaining_days,
        -(MembershipLevels::MEMBERSHIP_RANK[c&.membership_level] || 0),
        -(c&.total_amount || 0).to_f,
        r.identity_key
      ]
    end
  end

  def customers_by_email(rows)
    emails = rows.map { |r| r.representative_cycle.email }.uniq
    return {} if emails.empty?

    ShoplineCustomer.where(email: emails).select(:email, :membership_level, :total_amount).index_by(&:email)
  end
end
