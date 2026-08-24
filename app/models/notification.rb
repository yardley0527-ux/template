# frozen_string_literal: true

# Notification Board record. Generated exclusively by NotificationEngine's
# rule classes (app/services/notification_rules/*) via upsert_and_resolve! —
# never created directly by a controller. Controllers only drive the
# workflow state machine below (assign/start/request_verification/snooze/
# dismiss) plus the auto-resolve path the engine calls when a rule's
# condition stops firing.
#
# Status lifecycle (see 營運提醒中心 redesign spec):
#   detected -> pending_assignment (P0/P1 land here on creation) -> in_progress
#     -> pending_verification -> resolved (only the engine can set this,
#        once the underlying condition is confirmed cleared on a later run)
#   any active status -> snoozed (resumes automatically once snoozed_until passes)
#   any active status -> dismissed (always requires dismissal_reason)
#
# "Active" = not resolved and not dismissed. The partial unique index on
# deduplication_key covers every active status (see migration
# ReworkNotificationWorkflowFields) so a snoozed/pending_verification row
# still blocks the engine from creating a duplicate for the same condition.
class Notification < ApplicationRecord
  KINDS       = %w[alert opportunity].freeze
  CATEGORIES  = %w[system_health inventory_attention event_attention customer_runout
                   customer_overdue high_spender_no_second vip_silent product_attention
                   promotion_opportunity livestream_schedule_gap livestream_preparation
                   livestream_day_attention livestream_performance_drop livestream_review_due].freeze
  SEVERITIES  = %w[critical warning opportunity info].freeze
  PRIORITIES  = %w[P0 P1 P2 P3].freeze
  STATUSES    = %w[detected pending_assignment in_progress pending_verification
                   resolved snoozed dismissed].freeze
  ACTIVE_STATUSES = STATUSES - %w[resolved dismissed]
  DISMISSAL_REASONS = %w[misjudged not_applicable known_risk permanently_excluded].freeze
  # P0/P1 不可以無理由忽略：這兩個 reason 才算「有實質理由」，misjudged/not_applicable
  # 對高優先級問題來說幾乎不可能是真的（要嘛是系統誤判該去修規則，要嘛就是真的要處理）。
  DISMISSIBLE_REASONS_FOR_HIGH_PRIORITY = %w[known_risk permanently_excluded].freeze

  # 9 個既有規則類別 + 5 個新的直播監控規則類別，各自映射到使用者看的
  # 5 大 Category（客戶商機／商品營收／庫存到貨／直播活動／系統健康）。
  BROAD_CATEGORY = {
    "customer_runout"             => "customer_opportunity",
    "customer_overdue"            => "customer_opportunity",
    "high_spender_no_second"      => "customer_opportunity",
    "vip_silent"                  => "customer_opportunity",
    "promotion_opportunity"       => "customer_opportunity",
    "product_attention"           => "product_revenue",
    "inventory_attention"         => "inventory",
    "event_attention"             => "livestream_event",
    "system_health"               => "system_health",
    "livestream_schedule_gap"     => "livestream_event",
    "livestream_preparation"      => "livestream_event",
    "livestream_day_attention"    => "livestream_event",
    "livestream_performance_drop" => "livestream_event",
    "livestream_review_due"       => "livestream_event"
  }.freeze
  BROAD_CATEGORIES = %w[customer_opportunity product_revenue inventory livestream_event system_health].freeze

  belongs_to :owner, class_name: "User", foreign_key: :owner_user_id, optional: true

  validates :notification_key, :kind, :category, :severity, :priority, :title, :status,
            :deduplication_key, :first_detected_at, :last_detected_at, presence: true
  validates :kind,     inclusion: { in: KINDS }
  validates :category, inclusion: { in: CATEGORIES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status,   inclusion: { in: STATUSES }
  validates :dismissal_reason, inclusion: { in: DISMISSAL_REASONS }, allow_nil: true
  validates :occurrence_count, :reopened_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  # 只在「還沒結案」範圍內檢查唯一，對齊 DB 的 partial unique index
  # (idx_notifications_dedup_key_unique_active, WHERE status NOT IN resolved/dismissed).
  validates :deduplication_key, uniqueness: { conditions: -> { where.not(status: %w[resolved dismissed]) } }
  validate :dismissal_reason_present_when_dismissed
  validate :high_priority_requires_substantive_dismissal_reason
  validate :snooze_fields_present_when_snoozed

  scope :active,       -> { where.not(status: %w[resolved dismissed]) }
  # 舊名保留給既有呼叫端（controller/rules/tests 大量使用 open_status），
  # 語意從「status='open'」變成「還沒結案」，範圍不變（呼叫端要的本來就是這個）。
  scope :open_status,  -> { active }
  scope :unread,       -> { active.where(read_at: nil) }
  scope :by_category,  ->(c) { where(category: c) }
  scope :by_priority,  ->(p) { where(priority: p) }
  scope :critical,     -> { where(severity: "critical") }
  scope :high_priority, -> { where(priority: %w[P0 P1]) }
  scope :recent_first, -> { order(last_detected_at: :desc) }
  scope :overdue,      -> { active.where("due_at IS NOT NULL AND due_at < ?", Time.current) }
  scope :due_today,    -> { active.where(due_at: Time.current.all_day) }
  scope :awaiting_verification, -> { where(status: "pending_verification") }
  scope :currently_snoozed, -> { where(status: "snoozed").where("snoozed_until IS NULL OR snoozed_until > ?", Time.current) }
  scope :snooze_expired, -> { where(status: "snoozed").where("snoozed_until IS NOT NULL AND snoozed_until <= ?", Time.current) }
  scope :resolved_today, -> { where(status: "resolved").where(resolved_at: Time.current.all_day) }

  PRIORITY_RANK = { "P0" => 0, "P1" => 1, "P2" => 2, "P3" => 3 }.freeze

  def self.priority_rank_sql
    "CASE priority " + PRIORITY_RANK.map { |p, r| "WHEN '#{p}' THEN #{r}" }.join(" ") + " ELSE 9 END"
  end

  def broad_category
    BROAD_CATEGORY.fetch(category, category)
  end

  def read?
    read_at.present?
  end

  def overdue?
    due_at.present? && due_at < Time.current && !%w[resolved dismissed].include?(status)
  end

  def high_priority?
    %w[P0 P1].include?(priority)
  end

  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  # 分派負責人（可同時設定期限）。未結案狀態一律轉成 in_progress——
  # 「指派」本身就是有人要開始處理的訊號，不需要停在 pending_assignment
  # 讓管理者再多按一次「開始處理」。
  def assign!(user, due_at: nil)
    attrs = { owner_user_id: user.id, status: "in_progress" }
    attrs[:due_at] = due_at if due_at.present?
    update!(attrs)
  end

  # 沒有要換負責人，純粹「我要開始處理」（例如自己認領一張 detected 卡）。
  def start!(actor)
    attrs = { status: "in_progress" }
    attrs[:owner_user_id] = actor.id if owner_user_id.blank?
    update!(attrs)
  end

  # 「已處理」不能直接關卡：自動監控型提醒要進 pending_verification，
  # 等下一輪引擎確認條件真的不存在了，才會被 auto_resolve! 真正結案。
  def request_verification!(actor:, resolution_reason:)
    update!(status: "pending_verification", resolution_reason: resolution_reason,
           owner_user_id: owner_user_id || actor.id)
  end

  # 只由 NotificationEngine 呼叫：這一輪規則沒有再回報這個 dedup_key，
  # 代表條件已經不存在了，不管手動流程走到哪一步都直接結案。
  def auto_resolve!
    update!(status: "resolved", resolved_at: Time.current,
           metadata: metadata.merge("resolved_by" => "auto"))
  end

  # 手動關閉也保留（例如客戶商機類卡片沒有「重新偵測確認」的意義，
  # 分派完客服任務就是處理完了），但預設走 request_verification! 的監控型
  # 提醒不應該呼叫這個方法直接關閉——由呼叫端（controller）依 category 決定。
  def resolve!(auto: false)
    update!(status: "resolved", resolved_at: Time.current,
           metadata: metadata.merge("resolved_by" => auto ? "auto" : "manual"))
  end

  # 引擎重新看到「已經在 pending_verification 的 dedup_key」還在持續發生，
  # 代表剛才標記的處理沒有真的解決問題——退回 in_progress 讓人重新確認，
  # 不能悄悄留在 pending_verification 假裝在等驗證。
  def reopen_after_failed_verification!
    update!(status: "in_progress",
           metadata: metadata.merge("verification_failed_at" => Time.current.iso8601))
  end

  def snooze!(until_at:, reason:)
    pre_snooze_status = status
    update!(status: "snoozed", snoozed_until: until_at, snooze_reason: reason,
           metadata: metadata.merge("pre_snooze_status" => pre_snooze_status))
  end

  # 延後到期後自動醒來，回到暫存的前一個狀態（通常是 in_progress／detected）。
  def wake_from_snooze!
    return unless status == "snoozed"

    prior = metadata["pre_snooze_status"]
    prior = "detected" unless STATUSES.include?(prior)
    update!(status: prior, snoozed_until: nil)
  end

  def self.wake_expired_snoozes!
    snooze_expired.find_each(&:wake_from_snooze!)
  end

  def dismiss!(reason:, actor: nil)
    raise ArgumentError, "dismissal_reason is required" if reason.blank?
    if high_priority? && DISMISSIBLE_REASONS_FOR_HIGH_PRIORITY.exclude?(reason)
      raise ArgumentError, "P0/P1 notifications can only be dismissed with reason: known_risk or permanently_excluded"
    end

    update!(status: "dismissed", dismissed_at: Time.current, dismissal_reason: reason,
           owner_user_id: owner_user_id || actor&.id)
  end

  private

  def dismissal_reason_present_when_dismissed
    errors.add(:dismissal_reason, "must be present when dismissed") if status == "dismissed" && dismissal_reason.blank?
  end

  def high_priority_requires_substantive_dismissal_reason
    return unless status == "dismissed" && high_priority?

    unless DISMISSIBLE_REASONS_FOR_HIGH_PRIORITY.include?(dismissal_reason)
      errors.add(:dismissal_reason, "P0/P1 notifications require known_risk or permanently_excluded")
    end
  end

  def snooze_fields_present_when_snoozed
    return unless status == "snoozed"

    errors.add(:snoozed_until, "must be present when snoozed") if snoozed_until.blank?
    errors.add(:snooze_reason, "must be present when snoozed") if snooze_reason.blank?
  end
end
