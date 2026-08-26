# social／crm 角色開放 body_goals_kocs、betterbio_kocs、dianbopopo_kocs 三個新業配名單頁，
# 跟現有 kocs（Hiff）的權限一致。
class GrantBrandKocPagePermissions < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  CONTROLLERS = %w[body_goals_kocs betterbio_kocs dianbopopo_kocs].freeze
  ROLE_KEYS = %w[social crm].freeze

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
