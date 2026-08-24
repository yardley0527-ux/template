# social（社群部）角色重新開放每日訂單明細頁權限。
class RegrantSocialRoleDailyOrdersPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "social")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "daily_orders")
  end

  def down
    role = MigrationRole.find_by(key: "social")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "daily_orders").destroy_all
  end
end
