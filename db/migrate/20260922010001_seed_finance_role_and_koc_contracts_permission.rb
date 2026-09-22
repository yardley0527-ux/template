# 財務部帳號：只需要能開合約狀態頁打勾寄出/收到合約日期，不應該碰到 KOC 名單頁
# 其他社群/物流欄位，所以另開一個 role 而不是沿用既有的 social/logistics。
class SeedFinanceRoleAndKocContractsPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_or_create_by!(key: "finance") { |r| r.name = "財務部" }
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "koc_contracts")
  end

  def down
    role = MigrationRole.find_by(key: "finance")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "koc_contracts").destroy_all
    role.destroy if role.users.none?
  end
end
