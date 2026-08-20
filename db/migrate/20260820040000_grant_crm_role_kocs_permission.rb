# crmdata 帳號（crm role）也要能看 KOC 業配名單頁（填公關品寄出日期/物流部備註）。
class GrantCrmRoleKocsPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "crm")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "kocs")
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "kocs").destroy_all
  end
end
