# crmdata 帳號（crm role）也要能看 ManyChat 新客追蹤。
class GrantCrmRoleManychatLeadsPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "manychat_leads")
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "manychat_leads").destroy_all
  end
end
