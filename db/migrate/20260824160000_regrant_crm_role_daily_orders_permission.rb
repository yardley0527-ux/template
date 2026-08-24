# crmdata 帳號（crm role）重新開放每日訂單明細頁權限（8/20 曾移除，見 RevokeCrmRoleDailyOrdersPermission）。
class RegrantCrmRoleDailyOrdersPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "crm")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "daily_orders")
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "daily_orders").destroy_all
  end
end
