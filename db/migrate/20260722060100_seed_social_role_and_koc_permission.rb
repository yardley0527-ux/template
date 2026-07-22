# 社群部帳號：只需要能開 KOC 名單頁更新拍影片狀態，不應該有其他頁面權限，
# 所以另開一個 role 而不是沿用既有的 crm/data/logistics（都各自對應別的頁面群）。
class SeedSocialRoleAndKocPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_or_create_by!(key: "social") { |r| r.name = "社群部" }
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "kocs")
  end

  def down
    role = MigrationRole.find_by(key: "social")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: "kocs").destroy_all
    role.destroy if role.users.none?
  end
end
