# 總編輯等外部協作者：只能看 SEO 每日報告，不能看營運數據（登入後首頁會直接導到
# /seo_reports，見 WelcomeController）。
class SeedSeoViewerRole < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    role = MigrationRole.find_or_create_by!(key: "seo_viewer") { |r| r.name = "SEO 報告檢視" }
    MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "seo_reports")
  end

  def down
    role = MigrationRole.find_by(key: "seo_viewer")
    return unless role

    MigrationPagePermission.where(role_id: role.id).delete_all
    role.destroy
  end
end
