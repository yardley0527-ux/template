# Akimia（akimia_official）業配名單，跟其他品牌 KOC 表同一套結構。
class CreateAkimiaKocs < ActiveRecord::Migration[7.1]
  def change
    create_table :akimia_kocs do |t|
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
    add_index :akimia_kocs, :ig_username, unique: true
  end
end
