# frozen_string_literal: true

# Notification Board record. Generated exclusively by NotificationEngine's
# 9 rule classes (app/services/notification_rules/*) via
# upsert_open!/auto_resolve_stale! — never created directly by a controller.
class Notification < ApplicationRecord
  KINDS       = %w[alert opportunity].freeze
  CATEGORIES  = %w[system_health inventory_attention event_attention customer_runout
                   customer_overdue high_spender_no_second vip_silent product_attention
                   promotion_opportunity].freeze
  SEVERITIES  = %w[critical warning opportunity info].freeze
  STATUSES    = %w[open resolved dismissed].freeze

  validates :notification_key, :kind, :category, :severity, :title, :status,
            :deduplication_key, :first_detected_at, :last_detected_at, presence: true
  validates :kind,     inclusion: { in: KINDS }
  validates :category, inclusion: { in: CATEGORIES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status,   inclusion: { in: STATUSES }
  # 只在「開啟中」範圍內檢查唯一，對齊 DB 的 partial unique index
  # （idx_notifications_dedup_key_unique_open, WHERE status='open'）——
  # 同一個 dedup_key 的歷史 resolved/dismissed 列本來就允許並存，
  # 這裡的驗證條件必須跟資料庫索引的條件完全一致，否則 Rails 驗證層
  # 會比資料庫更嚴格，擋下資料庫其實允許的「條件恢復後開新週期」寫入。
  validates :deduplication_key, uniqueness: { conditions: -> { where(status: "open") } }

  scope :open_status,  -> { where(status: "open") }
  scope :unread,       -> { open_status.where(read_at: nil) }
  scope :by_category,  ->(c) { where(category: c) }
  scope :critical,     -> { where(severity: "critical") }
  scope :recent_first, -> { order(last_detected_at: :desc) }

  def read?
    read_at.present?
  end

  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  def resolve!(auto: false)
    update!(status: "resolved", resolved_at: Time.current,
           metadata: metadata.merge("resolved_by" => auto ? "auto" : "manual"))
  end

  def dismiss!
    update!(status: "dismissed", dismissed_at: Time.current)
  end
end
