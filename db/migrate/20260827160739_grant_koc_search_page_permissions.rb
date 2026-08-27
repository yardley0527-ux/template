# social／crm 角色開放新的跨品牌業配名單搜尋頁（koc_search），
# 跟現有 6 個品牌業配名單頁的權限一致。
class GrantKocSearchPagePermissions < ActiveRecord::Migration[7.1]
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

      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "koc_search")
    end
  end

  def down
    role_ids = MigrationRole.where(key: ROLE_KEYS).pluck(:id)
    MigrationPagePermission.where(role_id: role_ids, controller_name: "koc_search").destroy_all
  end
end
