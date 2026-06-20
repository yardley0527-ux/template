class CreateReloveKocs < ActiveRecord::Migration[7.1]
  def change
    create_table :relove_kocs do |t|
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

      t.timestamps
    end
    add_index :relove_kocs, :ig_username, unique: true
  end
end
