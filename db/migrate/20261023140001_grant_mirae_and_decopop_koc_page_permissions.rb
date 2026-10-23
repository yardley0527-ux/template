# social／crm 角色開放 mirae_kocs、decopop_kocs 業配名單頁，跟其他品牌一致。
class GrantMiraeAndDecopopKocPagePermissions < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  ROLE_KEYS = %w[social crm].freeze
  CONTROLLERS = %w[mirae_kocs decopop_kocs].freeze

  def up
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      CONTROLLERS.each do |controller_name|
        MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: controller_name)
      end
    end
  end

  def down
    role_ids = MigrationRole.where(key: ROLE_KEYS).pluck(:id)
    MigrationPagePermission.where(role_id: role_ids, controller_name: CONTROLLERS).destroy_all
  end
end
