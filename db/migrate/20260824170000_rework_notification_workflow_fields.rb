# 營運提醒中心改版：把「已讀」跟「已完成」分開，加入分派/期限/延後/再次發生追蹤，
# 並把 priority（P0-P3，處理急迫度）從 severity（原本混雜嚴重度與類型）拆出來。
#
# status 從 open/resolved/dismissed 三值擴充為：
#   detected / pending_assignment / in_progress / pending_verification /
#   resolved / snoozed / dismissed
# 既有 'open' 資料依 priority 分流：P0/P1 → pending_assignment（需要立刻指派），
# 其餘 → detected（已偵測，尚待分診）。
#
# 唯一索引（dedup_key）原本只擋 status='open'，現在要擋「所有還沒結案」的狀態
# （即 status NOT IN resolved/dismissed），否則同一個 dedup_key 在 snoozed／
# pending_verification 期間會被引擎誤判成「沒有這張卡」而重複建立。
class ReworkNotificationWorkflowFields < ActiveRecord::Migration[7.1]
  class MigrationNotification < ActiveRecord::Base
    self.table_name = "notifications"
  end

  def up
    add_column :notifications, :priority, :string
    add_column :notifications, :owner_user_id, :bigint
    add_column :notifications, :due_at, :datetime
    add_column :notifications, :snoozed_until, :datetime
    add_column :notifications, :snooze_reason, :text
    add_column :notifications, :dismissal_reason, :string
    add_column :notifications, :occurrence_count, :integer, default: 1, null: false
    add_column :notifications, :impact_summary, :text
    add_column :notifications, :recommended_action, :text
    add_column :notifications, :resolution_reason, :text
    add_column :notifications, :reopened_count, :integer, default: 0, null: false

    add_index :notifications, :owner_user_id
    add_index :notifications, :priority
    add_index :notifications, :due_at
    add_index :notifications, :snoozed_until
    add_foreign_key :notifications, :users, column: :owner_user_id

    severity_to_priority = { "critical" => "P0", "warning" => "P1", "opportunity" => "P2", "info" => "P3" }
    severity_to_priority.each do |severity, priority|
      MigrationNotification.where(severity: severity).update_all(priority: priority)
    end
    MigrationNotification.where(priority: nil).update_all(priority: "P2")
    change_column_null :notifications, :priority, false

    # 既有 status='open' 依 priority 分流成新狀態機的兩個起始態
    MigrationNotification.where(status: "open", priority: %w[P0 P1]).update_all(status: "pending_assignment")
    MigrationNotification.where(status: "open").update_all(status: "detected")

    remove_index :notifications, name: "idx_notifications_dedup_key_unique_open"
    add_index :notifications, :deduplication_key, unique: true,
      where: "(status NOT IN ('resolved', 'dismissed'))", name: "idx_notifications_dedup_key_unique_active"
  end

  def down
    remove_index :notifications, name: "idx_notifications_dedup_key_unique_active"
    add_index :notifications, :deduplication_key, unique: true,
      where: "((status)::text = 'open'::text)", name: "idx_notifications_dedup_key_unique_open"

    MigrationNotification.where(status: %w[detected pending_assignment in_progress pending_verification snoozed])
                          .update_all(status: "open")

    remove_foreign_key :notifications, column: :owner_user_id
    remove_column :notifications, :priority
    remove_column :notifications, :owner_user_id
    remove_column :notifications, :due_at
    remove_column :notifications, :snoozed_until
    remove_column :notifications, :snooze_reason
    remove_column :notifications, :dismissal_reason
    remove_column :notifications, :occurrence_count
    remove_column :notifications, :impact_summary
    remove_column :notifications, :recommended_action
    remove_column :notifications, :resolution_reason
    remove_column :notifications, :reopened_count
  end
end
