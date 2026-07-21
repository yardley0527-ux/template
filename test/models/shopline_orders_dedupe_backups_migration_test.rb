# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20260721120000_create_shopline_orders_dedupe_backups"

# Postgres DDL is transactional, and Rails wraps each test in a transaction
# that rolls back afterward — so it's safe to actually drop/recreate this
# table within a test; nothing persists past the test.
class ShoplineOrdersDedupeBackupsMigrationTest < ActiveSupport::TestCase
  def run_migration(direction)
    migration = CreateShoplineOrdersDedupeBackups.new
    migration.instance_variable_set(:@output, nil)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  test "down succeeds and drops the table when it is empty" do
    assert_equal 0, ShoplineOrdersDedupeBackup.count

    # 不查詢已被 DROP 的表（Postgres 交易一旦出錯就整個中毒，連 ensure 的
    # 復原都會失敗）——不拋例外本身就是成功；交易結束由 Rails 測試包裝自動
    # rollback 還原，不需要手動 run_migration(:up) 復原。
    assert_nothing_raised { run_migration(:down) }
  end

  test "down refuses and raises IrreversibleMigration when backups exist, table untouched" do
    ShoplineOrdersDedupeBackup.create!(
      original_id: 1, kept_id: 2, dedupe_run_id: "guard-test",
      order_number: "#GUARD", product_name: "test", quantity: 1, checkout_amount: 100,
      email: "guard@example.com", order_date: Time.current, created_at: Time.current
    )

    error = assert_raises(ActiveRecord::IrreversibleMigration) { run_migration(:down) }

    assert_match(/1 row/, error.message)
    assert_match(/DELETE FROM shopline_orders_dedupe_backups/, error.message)
    # 表沒被動：資料還在，仍然是 create_table 之後的正常結構。
    assert_equal 1, ShoplineOrdersDedupeBackup.count
  end
end
