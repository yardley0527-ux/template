# frozen_string_literal: true

# Corrects the initial migration's blanket unique index. Spec item 4 ("恢復後
# 再次發生可建立新事件週期") requires the SAME deduplication_key to be usable
# again after a notification resolves — a condition that clears and later
# recurs should start a fresh cycle (new first_detected_at), not silently
# reopen old history. A blanket unique index across all statuses would make
# that impossible; scoping uniqueness to status='open' allows unlimited
# resolved/dismissed rows to share a key while still preventing two OPEN
# rows for the same condition (the actual fatigue-control guarantee).
class MakeNotificationsDedupKeyUniqueWhileOpen < ActiveRecord::Migration[7.1]
  def change
    remove_index :notifications, :deduplication_key
    add_index :notifications, :deduplication_key, unique: true,
      where: "status = 'open'", name: "idx_notifications_dedup_key_unique_open"
  end
end
