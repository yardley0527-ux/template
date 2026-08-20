# 社群部帳號（social role）也要能看 Podcast/KOL 聯絡名單頁，比照既有的 Hiff 業配名單頁權限。
class GrantSocialRolePodcastAndKolContactsPermission < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_by!(key: "social")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "podcast_contacts")
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "kol_contacts")
  end

  def down
    role = MigrationRole.find_by(key: "social")
    return unless role

    MigrationPagePermission.where(role_id: role.id, controller_name: %w[podcast_contacts kol_contacts]).destroy_all
  end
end
