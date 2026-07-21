# frozen_string_literal: true

# Notification Board record. Generated exclusively by NotificationEngine's
# 8 rule classes (app/services/notification_rules/*) via
# upsert_open!/auto_resolve_stale! — never created directly by a controller.
class Notification < ApplicationRecord
  KINDS       = %w[alert opportunity].freeze
  CATEGORIES  = %w[system_health inventory_attention event_attention customer_runout
                   customer_overdue high_spender_no_second vip_silent product_attention].freeze
  SEVERITIES  = %w[critical warning opportunity info].freeze
  STATUSES    = %w[open resolved dismissed].freeze

  validates :notification_key, :kind, :category, :severity, :title, :status,
            :deduplication_key, :first_detected_at, :last_detected_at, presence: true
  validates :kind,     inclusion: { in: KINDS }
  validates :category, inclusion: { in: CATEGORIES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status,   inclusion: { in: STATUSES }
  validates :deduplication_key, uniqueness: true

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
