# crmdata 帳號（crm role）也要能看／更新 ManyChat 每日確認面板。
class GrantCrmRoleManychatChecksPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "crm")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "manychat_checks")
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "manychat_checks").destroy_all
  end
end
