# coindevanity 抓錯帳號了（那個IG story連結是別人標記的，不是「微電流面膜」官方帳號），
# 正確帳號是 akimia_official，改用 AkimiaKoc（見 CreateAkimiaKocs）。這裡把
# coindevanity_kocs 表跟對應的頁面權限都清掉，不留一個掛著沒人用、資料還是錯的表。
class DropCoindevanityKocs < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  def up
    MigrationPagePermission.where(controller_name: "coindevanity_kocs").destroy_all
    drop_table :coindevanity_kocs
  end

  def down
    create_table :coindevanity_kocs do |t|
      t.string "ig_username"
      t.string "ig_full_name"
      t.string "ig_user_id"
      t.string "email"
      t.string "alias"
      t.string "profile_url"
      t.string "status"
      t.boolean "has_paid_partnership"
      t.integer "post_count"
      t.integer "max_likes"
      t.integer "max_video_views"
      t.datetime "last_post_at"
      t.string "last_post_url"
      t.string "source"
      t.text "notes"
      t.boolean "follows_chloe_ig", default: false, null: false
      t.boolean "follows_official_ig", default: false, null: false
      t.string "video_shoot_status", default: "未拍攝", null: false
      t.boolean "email_sent", default: false, null: false
      t.text "logistics_notes"
      t.date "pr_gift_shipped_at"
      t.timestamps
    end
    add_index :coindevanity_kocs, :ig_username, unique: true

    %w[social crm].each do |key|
      role = MigrationRole.find_by(key: key)
      next unless role

      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "coindevanity_kocs")
    end
  end
end
