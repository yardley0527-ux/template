# frozen_string_literal: true

require Rails.root.join("lib/shopline_orders_maintenance_lock") if defined?(Rails)

# Restores rows previously deleted by ShoplineOrdersDedupeService#apply, from
# shopline_orders_dedupe_backups, scoped to exactly one dedupe_run_id — never
# "everything ever backed up". dry_run never writes; apply requires an
# explicit apply: true (the rake task requires APPLY=1, matching the other
# maintenance tools).
#
# Idempotent by construction: each backup row has a restored_at column, set
# the moment it is re-inserted. apply only ever operates on
# WHERE dedupe_run_id = ? AND restored_at IS NULL — running it twice for the
# same run_id finds nothing pending the second time, not a fuzzy
# content-match. No FK references shopline_orders.id from anywhere else in
# the schema, so the restored row gets a fresh id — original numeric ids are
# not (and do not need to be) preserved.
#
# The restored row is written with a placeholder source_row_hash
# ("restored:<uuid>", never valid hex, so it structurally cannot collide
# with any real content_hash output) — restoring intentionally does NOT
# duplicate the occurrence-assignment logic that ShoplineOrdersRehashService
# already owns and has its own collision check for. The Runbook requires
# running `shopline_orders:rehash_content_ids APPLY=1` immediately after any
# restore to give restored rows their real canonical hash; until that runs,
# a restored row simply will not be matched by a future import (it will
# insert instead of updating in place), same as any other stale-hash row.
#
# If restoring recreates a row alongside content some *other* row already
# represents (e.g. dedupe was correct and something else independently
# re-created the same content since), that is the deliberate, correct
# outcome of "undo this dedupe run" — restore is only ever invoked because a
# human decided a specific dedupe_run_id should not have happened, so ending
# up with 2 rows again (matching pre-dedupe state) is the goal, not a bug.
class ShoplineOrdersRestoreService
  def self.call(dedupe_run_id:, apply: false)
    new(dedupe_run_id: dedupe_run_id, apply: apply).call
  end

  def initialize(dedupe_run_id:, apply: false)
    @dedupe_run_id = dedupe_run_id
    @apply = apply
  end

  def call
    return dry_run_report unless @apply

    acquired, result = ShoplineOrdersMaintenanceLock.try_with_lock { run_apply }
    return result if acquired

    { dedupe_run_id: @dedupe_run_id, applied: false, aborted: true,
      abort_reason: "lock_busy — the importer or another rehash/dedupe/restore run holds " \
                    "#{ShoplineOrdersMaintenanceLock::NAME}" }
  end

  private

  def dry_run_report
    report(pending_scope).merge(applied: false)
  end

  def run_apply
    pending = pending_scope.to_a # snapshot fresh, right now, inside the lock

    if pending.empty?
      return report([]).merge(applied: true, restored_count: 0)
    end

    restored_ids = []
    ActiveRecord::Base.transaction do
      pending.each do |backup|
        order = ShoplineOrder.create!(
          order_number: backup.order_number, product_name: backup.product_name,
          quantity: backup.quantity, checkout_amount: backup.checkout_amount,
          total_amount: backup.total_amount, email: backup.email, order_date: backup.order_date,
          import_run_id: backup.import_run_id, payment_status: "已付款",
          source_row_hash: "restored:#{SecureRandom.uuid}"
        )
        backup.update!(restored_at: Time.current)
        restored_ids << order.id
      end
    end

    report(pending).merge(applied: true, restored_count: restored_ids.size,
                          verification: verify(pending, restored_ids))
  end

  def pending_scope
    ShoplineOrdersDedupeBackup.where(dedupe_run_id: @dedupe_run_id, restored_at: nil)
  end

  # 聚合數字＋涉及人數/訂單數，不輸出 email/姓名/電話本身。
  def report(pending)
    all_for_run = ShoplineOrdersDedupeBackup.where(dedupe_run_id: @dedupe_run_id)
    {
      dedupe_run_id: @dedupe_run_id,
      total_backed_up: all_for_run.count,
      pending_restore_count: pending.size,
      already_restored_count: all_for_run.where.not(restored_at: nil).count,
      affected_customers: pending.map(&:email).uniq.compact.size,
      affected_orders: pending.map(&:order_number).uniq.size
    }
  end

  def verify(pending, restored_ids)
    {
      restored_ids_present: ShoplineOrder.where(id: restored_ids).count == restored_ids.size,
      backups_marked_restored: ShoplineOrdersDedupeBackup.where(id: pending.map(&:id)).where.not(restored_at: nil).count == pending.size,
      note: "run `shopline_orders:rehash_content_ids APPLY=1` next to give restored rows their real canonical hash"
    }
  end
end
