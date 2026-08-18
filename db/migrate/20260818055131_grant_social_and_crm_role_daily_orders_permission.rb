# social（社群部）、crm（crmdata 帳號）兩個角色也要能看每日訂單明細頁，補上頁面權限。
class GrantSocialAndCrmRoleDailyOrdersPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  ROLE_KEYS = %w[social crm].freeze

  def up
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by!(key: key)
      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "daily_orders")
    end
  end

  def down
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      MigrationPagePermission.where(role_id: role.id, controller_name: "daily_orders").destroy_all
    end
  end
end
