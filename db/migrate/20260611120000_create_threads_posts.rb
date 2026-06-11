class CreateThreadsPosts < ActiveRecord::Migration[7.1]
  def change
    create_table :threads_posts do |t|
      t.string   :post_id,      null: false
      t.string   :username
      t.string   :full_name
      t.text     :text_content
      t.integer  :like_count,   default: 0
      t.integer  :reply_count,  default: 0
      t.integer  :repost_count, default: 0
      t.string   :post_url
      t.string   :keyword
      t.datetime :posted_at
      t.date     :fetched_on
      t.timestamps
    end
    add_index :threads_posts, :post_id,   unique: true
    add_index :threads_posts, :fetched_on
    add_index :threads_posts, :keyword
  end
end
