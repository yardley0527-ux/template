# frozen_string_literal: true

# Single shared Postgres advisory lock covering every operation that writes
# to shopline_orders based on source_row_hash identity: the daily importer,
# ShoplineOrdersRehashService#apply, and ShoplineOrdersDedupeService. At most
# one of these three can run at a time.
#
# Non-blocking by design (pg_try_advisory_lock, not pg_advisory_lock): a
# caller that finds the lock busy gets an immediate, clear "busy" result
# instead of queuing invisibly — matches the existing convention in
# CrmRollupRunner's per-product lock ("second concurrent call skips instead
# of blocking").
#
# Why the importer needs this too: without it, running rehash or dedupe
# concurrently with an in-flight import races on the same rows — an import
# could insert a row using the NEW hash formula for content rehash hasn't
# reached yet, or dedupe could delete a row the import is mid-way through
# updating. Locking the importer closes that window from the write side, not
# just by "scheduling outside typical import hours" (see the deployment
# runbook for why that alone is not sufficient).
module ShoplineOrdersMaintenanceLock
  NAME = "shopline_orders_write"

  # Attempts to acquire the lock, yields if successful, always releases
  # afterward. Returns [true, block_result] on success or [false, nil] if
  # another holder currently has it — never blocks.
  def self.try_with_lock
    conn = ActiveRecord::Base.connection
    key = conn.quote(NAME)
    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{key}))")
    )
    return [false, nil] unless acquired

    begin
      [true, yield]
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{key}))")
    end
  end
end
