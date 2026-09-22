# social（社群部）角色也要能看合約狀態頁，負責登記影片上架時間／廣告區間；
# 已寄合約/已收合約欄位仍然只有 finance 角色能改（見 koc_contracts_controller.rb）。
class GrantSocialRoleKocContractsPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by(key: "social")
    return unless role

    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "koc_contracts")
  end

  def down
    role = MigrationRole.find_by(key: "social")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "koc_contracts").destroy_all
  end
end
