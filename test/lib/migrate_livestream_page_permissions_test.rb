# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260721140000_migrate_livestream_page_permissions")

# 這支遷移在 db:test:prepare 時已經對（當時空無一物的）test DB 跑過一次
# up，不會再自動重跑；這裡直接呼叫 up 方法本身，針對「這次測試新建的資料」
# 驗證遷移邏輯（冪等、沒有舊權限的 role 不受影響、down 明確拒絕而非假裝可逆）。
class MigrateLivestreamPagePermissionsTest < ActiveSupport::TestCase
  def migration
    MigrateLivestreamPagePermissions.new
  end

  def role!(key_prefix)
    Role.create!(key: "#{key_prefix}-#{SecureRandom.hex(4)}", name: key_prefix)
  end

  test "role with old omnipotent_analysis permission gets livestream_product_analysis after up" do
    role = role!("mig-omni")
    PagePermission.create!(role: role, controller_name: "omnipotent_analysis")

    migration.up

    assert PagePermission.exists?(role: role, controller_name: "livestream_product_analysis")
    assert PagePermission.exists?(role: role, controller_name: "omnipotent_analysis"), "舊權限列必須保留，不刪除"
  end

  test "each of the 5 old product analysis permissions maps to livestream_product_analysis" do
    %w[turmeric_analysis metabolism_analysis glutathione_analysis probiotic_analysis omnipotent_analysis].each do |old|
      role = role!("mig-#{old}")
      PagePermission.create!(role: role, controller_name: old)
      migration.up
      assert PagePermission.exists?(role: role, controller_name: "livestream_product_analysis"), "#{old} 應該對應到 livestream_product_analysis"
    end
  end

  test "role with old livestream_analysis permission gets livestream_strategy after up" do
    role = role!("mig-la")
    PagePermission.create!(role: role, controller_name: "livestream_analysis")

    migration.up

    assert PagePermission.exists?(role: role, controller_name: "livestream_strategy")
  end

  test "role with old livestreams permission gets livestream_overview after up" do
    role = role!("mig-ls")
    PagePermission.create!(role: role, controller_name: "livestreams")

    migration.up

    assert PagePermission.exists?(role: role, controller_name: "livestream_overview")
  end

  test "role with no old permission is not granted anything by up" do
    role = role!("mig-none")
    PagePermission.create!(role: role, controller_name: "customers") # 不相干的既有權限

    migration.up

    assert_not PagePermission.exists?(role: role, controller_name: "livestream_overview")
    assert_not PagePermission.exists?(role: role, controller_name: "livestream_product_analysis")
    assert_not PagePermission.exists?(role: role, controller_name: "livestream_strategy")
    assert_equal 1, role.page_permissions.count, "不相干的 role 不該被新增任何一列"
  end

  test "up is idempotent: running twice does not create duplicate rows" do
    role = role!("mig-idem")
    PagePermission.create!(role: role, controller_name: "omnipotent_analysis")

    migration.up
    count_after_first = PagePermission.where(role: role, controller_name: "livestream_product_analysis").count
    migration.up
    count_after_second = PagePermission.where(role: role, controller_name: "livestream_product_analysis").count

    assert_equal 1, count_after_first
    assert_equal count_after_first, count_after_second
  end

  # ── 一（1）：up 如何判斷「新建立」vs「執行前已存在」──────────────────────
  # up 在 find_or_create_by! 之前先 exists? 查一次，只在「這次 up 呼叫」的
  # 記憶體生命週期內知道答案（用來寫進 `say` 執行摘要供部署時核對，不作為
  # down 的判斷依據——這個資訊不會被持久化，也刻意不新增追蹤表存它）。
  test "up distinguishes newly-created rows from already-present rows within the same call, reported via say" do
    role = role!("mig-distinguish")
    PagePermission.create!(role: role, controller_name: "omnipotent_analysis")
    # 這個 role 事先就已經有新頁權限（模擬跟遷移無關的獨立授權）
    PagePermission.create!(role: role, controller_name: "livestream_product_analysis")

    other_role = role!("mig-distinguish-2")
    PagePermission.create!(role: other_role, controller_name: "probiotic_analysis")
    # other_role 沒有 livestream_product_analysis，這筆對 migration 而言才是「新建立」

    output = capture_migration_say { migration.up }

    assert_match(/granted 1 new page_permission row\(s\); 1 already present/, output)
  end

  # ── 一（2）：down 明確拒絕，而不是假裝可以「只刪自己新增的」─────────────

  test "down raises IrreversibleMigration and does not delete any permission rows" do
    role = role!("mig-down-refuse")
    PagePermission.create!(role: role, controller_name: "omnipotent_analysis")
    migration.up
    assert PagePermission.exists?(role: role, controller_name: "livestream_product_analysis")

    assert_raises(ActiveRecord::IrreversibleMigration) { migration.down }

    # down 拒絕執行本身不該有任何副作用——資料原封不動
    assert PagePermission.exists?(role: role, controller_name: "livestream_product_analysis")
    assert PagePermission.exists?(role: role, controller_name: "omnipotent_analysis")
  end

  private

  def capture_migration_say(&block)
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    block.call
    output.string
  ensure
    $stdout = original_stdout
  end
end
