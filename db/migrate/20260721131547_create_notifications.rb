# frozen_string_literal: true

# Notification Board data model. subject_id is a string (not bigint) because
# subjects vary by rule: a CrmProduct id, a customer identity_key (phone or
# lowercased email — see CustomerPurchaseSummary), or nil for system-level
# notifications with no single subject.
#
# deduplication_key is the whole safety mechanism for "notification fatigue
# control": one open row per (notification_key, subject, detection period).
# The generator upserts on this key — a still-firing condition updates
# last_detected_at on the existing row instead of creating a new one; a
# condition that stops firing gets auto-resolved (see NotificationEngine).
class CreateNotifications < ActiveRecord::Migration[7.1]
  def change
    create_table :notifications do |t|
      t.string   :notification_key, null: false
      t.string   :kind,             null: false # alert | opportunity
      t.string   :category,         null: false # system_health | inventory_attention | ...
      t.string   :severity,         null: false # critical | warning | opportunity | info
      t.string   :title,            null: false
      t.text     :message
      t.string   :subject_type
      t.string   :subject_id
      t.jsonb    :metadata,         null: false, default: {}
      t.string   :deduplication_key, null: false
      t.string   :status,           null: false, default: "open" # open | resolved | dismissed
      t.datetime :first_detected_at, null: false
      t.datetime :last_detected_at,  null: false
      t.datetime :read_at
      t.datetime :resolved_at
      t.datetime :dismissed_at

      t.timestamps
    end

    add_index :notifications, :deduplication_key, unique: true
    add_index :notifications, [:status, :category]
    add_index :notifications, [:status, :severity]
    add_index :notifications, :notification_key
    add_index :notifications, [:subject_type, :subject_id]
  end
end
