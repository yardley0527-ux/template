# social／crm 角色開放 akimia_kocs 業配名單頁，跟其他品牌一致。
class GrantAkimiaKocPagePermissions < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  ROLE_KEYS = %w[social crm].freeze

  def up
    ROLE_KEYS.each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "akimia_kocs")
    end
  end

  def down
    role_ids = MigrationRole.where(key: ROLE_KEYS).pluck(:id)
    MigrationPagePermission.where(role_id: role_ids, controller_name: "akimia_kocs").destroy_all
  end
end
