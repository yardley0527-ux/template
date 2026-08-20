# crmdata 帳號（crm role）移除每日訂單明細頁權限。
class RevokeCrmRoleDailyOrdersPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "crm")
    MigrationPagePermission.where(role_id: role.id, controller_name: "daily_orders").destroy_all
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "daily_orders")
  end
end
