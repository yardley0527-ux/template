# frozen_string_literal: true

# 顧客 × 產品 × 購買週期歷史。每一次符合追蹤產品的有效購買都會產生一列，
# 與 CrmCustomerProductTracking（只保留最新一筆快照的 rollup cache）並存──
# 這張表刻意保留每個週期各自的狀態，才能做人工覆寫、下一筆訂單配對分類，
# 且互不影響。
#
# 只由 CrmCustomerProductCycleBuilderService（rollup upsert）與
# CrmCustomerProductCycleOverrideService（人工覆寫）寫入。
#
# Phase 1.5 修正：「跨品購買」與「同品最終是否回購」不是互斥的單一結果
# （例如 6/1 買A → 6/15 買B → 7/20 又買A：兩件事同時成立），所以拆成兩條
# 獨立追蹤線，不再塞進同一個 match_status 列舉裡：
#   - next_any_order_*（= matched_next_order_* 欄位別名）：購買後第一筆
#     任何產品的有效訂單，用來判斷 cross_product_purchase? 是否發生。
#   - next_same_product_order_*：購買後第一筆包含原產品的有效訂單，
#     match_status（加購/回購/尚未回購）只由這條線決定，不受跨品購買影響。
class CrmCustomerProductCycle < ApplicationRecord
  # match_status 只描述「同品」這條追蹤線的結果，跟是否發生跨品購買無關
  # （跨品購買用 cross_product_purchase? 另外表達，兩者可同時為真）。
  MATCH_STATUSES = %w[
    same_product_repurchase
    same_product_addon
    not_yet_repurchased
  ].freeze

  # Phase 2：人工狀態（客服在 Dashboard 操作後落地保存），nil 代表還沒有人工
  # 介入，此時顯示狀態改用日期即時算（due_today/due_soon/overdue，見
  # derived_status）。人工狀態一旦設定，優先於日期狀態顯示。
  FOLLOW_UP_STATUSES = %w[waiting_reply rescheduled paused repurchased].freeze
  DATE_DERIVED_STATUSES = %w[overdue due_today due_soon].freeze
  ALL_DASHBOARD_STATUSES = (DATE_DERIVED_STATUSES + FOLLOW_UP_STATUSES).freeze

  DUE_SOON_DAYS = 7

  STATUS_LABELS = {
    "overdue"        => "逾期未回購",
    "due_today"      => "今日待聯絡",
    "due_soon"       => "即將用完",
    "waiting_reply"  => "等待回覆",
    "rescheduled"    => "已排程再聯絡",
    "paused"         => "暫停追蹤",
    "repurchased"    => "已回購",
    "tracking"       => "追蹤中"
  }.freeze

  # 週期一旦自己被判定「同品已回購/加購」，代表有更新的週期列（該次回購本身）
  # 應該接手成為 active task；理論上「最新一列」的規則已經能自然做到這件事
  # （見 active_follow_up 註解），這裡是防禦性的第二層保險。
  ACTIVE_EXCLUDED_MATCH_STATUSES = %w[same_product_repurchase same_product_addon].freeze

  # 語意化別名：底層欄位名稱沿用 Phase 1 就有的 matched_next_order_*
  # （避免非必要的 migration），但這三欄實際代表的是「下一筆任何產品的
  # 訂單」，不是「配對到的訂單」，用 next_any_* 讀寫比較不會誤解。
  alias_attribute :next_any_order_number, :matched_next_order_number
  alias_attribute :next_any_order_date,   :matched_next_order_date
  alias_attribute :next_any_product_key,  :matched_next_product_key

  belongs_to :assigned_to, class_name: "User", foreign_key: :assigned_to_user_id, optional: true
  has_many :follow_up_events, class_name: "CrmCustomerProductFollowUpEvent",
           foreign_key: :cycle_id, dependent: :destroy, inverse_of: :cycle

  validates :identity_key, presence: true
  validates :email, presence: true
  validates :product_key, presence: true
  validates :cycle_started_at, presence: true
  validates :bottle_count, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :estimated_usage_days, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :estimated_finish_date, presence: true
  validates :suggested_contact_date, presence: true
  validates :match_status, presence: true, inclusion: { in: MATCH_STATUSES }
  validates :follow_up_status, inclusion: { in: FOLLOW_UP_STATUSES }, allow_nil: true
  validates :refreshed_at, presence: true
  validates :cycle_started_at,
            uniqueness: { scope: %i[identity_key product_key] }

  scope :for_product, ->(product_key) { where(product_key: product_key) }
  scope :open_cycles, -> { where(match_status: "not_yet_repurchased") }
  scope :matched, -> { where.not(match_status: "not_yet_repurchased") }
  scope :manually_overridden, -> {
    where.not(manual_override_remaining_days: nil).or(where.not(manual_override_finish_date: nil))
  }

  # ── Active follow-up projection（Phase 2）──────────────────────────
  #
  # Dashboard 的工作列表是「一位顧客 × 一項產品 × 一筆目前有效任務」，不是
  # 所有歷史 cycle。每一次新購買都會產生自己的一列 cycle（Phase 1
  # 設計），所以「目前有效任務」就是同一組 (identity_key, product_key) 裡
  # cycle_started_at 最新的那一列——這天然滿足「已完成同品回購的舊週期不
  # 可再變待辦」與「加購不可造成同一天兩筆待辦」：加購/回購本身的那次購買
  # 一定會產生一列更新的 cycle，把舊列從「最新」的位置擠掉。
  #
  # ACTIVE_EXCLUDED_MATCH_STATUSES 是防禦性的第二層：極端情況下（例如那筆
  # 更新購買剛好缺週期設定、build_cycle_row 略過沒建列），只排除掉舊列、
  # 不會退而求其次顯示一筆更舊、一樣過時的 cycle——沒有可靠的 active task
  # 時就是沒有，不能拿舊資料充數。
  #
  # 用 query 表達，不新增資料表、不修改任何既有 cycle 資料。
  def self.active_follow_up
    latest_ids_sql = <<~SQL
      SELECT DISTINCT ON (identity_key, product_key) id
      FROM crm_customer_product_cycles
      ORDER BY identity_key, product_key, cycle_started_at DESC
    SQL

    where("crm_customer_product_cycles.id IN (#{latest_ids_sql})")
      .where.not(match_status: ACTIVE_EXCLUDED_MATCH_STATUSES)
  end

  # ── Historical projection（Phase 3.1）───────────────────────────────
  #
  # active_follow_up 回答的是「現在」的 active task；歷史直播候選名單需要
  # 回答「以某個過去日期為基準，當時的 active task 是什麼」——這是不同的
  # 問題，不能直接用 active_follow_up 回推（match_status/
  # next_same_product_order_date 只反映「現在已知的最新事實」，例如直播後
  # 才發生的回購，會讓 match_status 提早變成 same_product_repurchase，
  # 但那件事在直播當下根本還沒發生）。
  #
  # 正確作法：
  #   1. 只看 cycle_started_at <= reference_date 的週期（直播之後才開始的
  #      週期，當時根本不存在）。
  #   2. 同一組 (identity_key, product_key) 取這個限制下最新的一筆。
  #   3. 排除條件改成明確比較 next_same_product_order_date <= reference_date
  #      （這筆週期「當時已經」被同品回購取代），而不是信任 match_status——
  #      如果那筆回購訂單晚於 reference_date，match_status 可能已經被之後
  #      的 rollup 更新成 same_product_repurchase，但這對「當時」不成立。
  def self.active_as_of(reference_date)
    conn = ActiveRecord::Base.connection
    quoted_date = conn.quote(reference_date)

    latest_ids_sql = <<~SQL
      SELECT DISTINCT ON (identity_key, product_key) id
      FROM crm_customer_product_cycles
      WHERE cycle_started_at <= #{quoted_date}
      ORDER BY identity_key, product_key, cycle_started_at DESC
    SQL

    where("crm_customer_product_cycles.id IN (#{latest_ids_sql})")
      .where(
        "next_same_product_order_date IS NULL OR next_same_product_order_date > ?",
        reference_date
      )
  end

  # effective_finish_date 的 SQL 版本，跟 Ruby 的 #effective_finish_date 邏輯
  # 必須完全一致（test 有互相校驗）。manual_override_at 是 UTC 存的
  # timestamp，跟 Phase 1.5 order_date 的坑一樣，::date 前要先轉回 Taipei，
  # 否則午夜前後 8 小時窗口會算錯一天。reference_date 一律由 Ruby 端傳入
  # （Date.current，尊重 config.time_zone），不用 DB 的 CURRENT_DATE，
  # 避免同一類時區問題。
  def self.remaining_days_sql(reference_date: Date.current)
    conn = ActiveRecord::Base.connection
    quoted_today = conn.quote(reference_date)

    finish_date_sql = <<~SQL.squish
      COALESCE(
        CASE WHEN manual_override_remaining_days IS NOT NULL
             THEN COALESCE(
                    (manual_override_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Taipei')::date,
                    #{quoted_today}
                  ) + manual_override_remaining_days
        END,
        manual_override_finish_date,
        estimated_finish_date
      )
    SQL

    "((#{finish_date_sql}) - #{quoted_today})"
  end

  # KPI 與列表共用的狀態篩選——狀態的定義只寫這一份，KPI 數字跟列表篩選結果
  # 保證一致。人工狀態（follow_up_status 有值）優先於日期狀態，跟
  # #derived_status 的邏輯對齊。
  def self.with_status_filter(scope, status, reference_date: Date.current)
    return scope if status.blank?

    remaining = remaining_days_sql(reference_date: reference_date)

    case status
    when *FOLLOW_UP_STATUSES
      scope.where(follow_up_status: status)
    when "overdue"
      scope.where(follow_up_status: nil).where("#{remaining} < 0")
    when "due_today"
      scope.where(follow_up_status: nil).where("#{remaining} = 0")
    when "due_soon"
      scope.where(follow_up_status: nil).where("#{remaining} BETWEEN 1 AND #{DUE_SOON_DAYS}")
    else
      scope.none
    end
  end

  # 預設排序優先序（規格：1.今日已逾期未處理 2.今日待聯絡 3.7天內即將用完
  # 4.其他追蹤中）。同樣只由人工狀態是否存在 + 日期共同決定，跟
  # with_status_filter 用同一份 remaining_days_sql。
  def self.sort_priority_sql(reference_date: Date.current)
    remaining = remaining_days_sql(reference_date: reference_date)

    <<~SQL.squish
      CASE
        WHEN follow_up_status IS NULL AND (#{remaining}) < 0 THEN 1
        WHEN follow_up_status IS NULL AND (#{remaining}) = 0 THEN 2
        WHEN follow_up_status IS NULL AND (#{remaining}) BETWEEN 1 AND #{DUE_SOON_DAYS} THEN 3
        ELSE 4
      END
    SQL
  end

  def manual_override?
    manual_override_remaining_days.present? || manual_override_finish_date.present?
  end

  # 人工覆寫優先序：manual_override_remaining_days > manual_override_finish_date
  # > 系統估算 estimated_finish_date。兩個覆寫欄位都有值時，天數覆寫優先，
  # 因為使用者通常是看著「還剩幾天」在調整,日期覆寫是次要輸入管道。
  #
  # 覆寫剩餘天數會以「覆寫當下」為基準換算成一個固定的用完日
  # （manual_override_at + remaining_days），之後隨著今天日期前進持續遞減──
  # 不是把 remaining_days 原樣凍結，否則過幾天畫面上的剩餘天數就會跟現實脫節。
  def effective_finish_date
    if manual_override_remaining_days.present?
      base_date = manual_override_at&.to_date || Date.current
      return base_date + manual_override_remaining_days
    end
    return manual_override_finish_date if manual_override_finish_date.present?

    estimated_finish_date
  end

  def effective_remaining_days
    (effective_finish_date - Date.current).to_i
  end

  def effective_overdue_days
    days = effective_remaining_days
    days.negative? ? -days : 0
  end

  # 購買後第一筆任何產品的訂單，是否為「別的」產品（不論同品之後有沒有
  # 回購都成立——兩件事各自獨立記錄，不互斥）。
  def cross_product_purchase?
    next_any_order_date.present? && next_any_product_key != product_key
  end

  def same_product_repurchase_completed?
    next_same_product_order_date.present?
  end

  # 同品回購間隔天數（含加購）；還沒回購則為 nil。
  def same_product_repurchase_days
    return nil unless next_same_product_order_date

    (next_same_product_order_date - cycle_started_at).to_i
  end

  # 人工狀態優先；沒有人工狀態時用日期即時算。跟 .with_status_filter /
  # .sort_priority_sql 的邏輯對齊，但這裡是 Ruby 版本，給畫面顯示單一 row 用
  # （分頁後的少量列，不會有 N+1 疑慮；SQL 版本才是給 WHERE/ORDER BY 用的）。
  def derived_status
    return follow_up_status if follow_up_status.present?

    days = effective_remaining_days
    return "overdue"   if days.negative?
    return "due_today" if days.zero?
    return "due_soon"  if days <= DUE_SOON_DAYS

    "tracking"
  end

  # 已回購標記當下，系統是否已經偵測到同品訂單（vs 純人工確認、沒有對應
  # 訂單）。只讀現有欄位，不會偽造 order_id。
  def system_detected_repurchase?
    next_same_product_order_date.present?
  end
end
