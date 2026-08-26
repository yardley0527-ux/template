class GrantTrackedCustomersPagePermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end
  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  # 跟 /customers 一樣的可視角色（見 page_permissions where controller_name='customers'）
  ROLE_KEYS = %w[crm data].freeze

  def up
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "tracked_customers")
    end
  end

  def down
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      MigrationPagePermission.where(role_id: role.id, controller_name: "tracked_customers").destroy_all
    end
  end
end
