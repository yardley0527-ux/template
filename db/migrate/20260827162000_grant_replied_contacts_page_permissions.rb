# 「已回覆待追蹤」彙整 8 個業配／聯絡名單的已回覆名單，開放給跟這些
# 名單本身相同的角色（social／crm），權限對齊 koc_search。
class GrantRepliedContactsPagePermissions < ActiveRecord::Migration[7.1]
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

      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "replied_contacts")
    end
  end

  def down
    role_ids = MigrationRole.where(key: ROLE_KEYS).pluck(:id)
    MigrationPagePermission.where(role_id: role_ids, controller_name: "replied_contacts").destroy_all
  end
end
