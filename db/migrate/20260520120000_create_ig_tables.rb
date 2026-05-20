class CreateIgTables < ActiveRecord::Migration[7.1]
  def change
    create_table :ig_profiles do |t|
      t.string  :username, null: false
      t.string  :display_name
      t.text    :bio
      t.integer :follower_count,  default: 0
      t.integer :following_count, default: 0
      t.integer :post_count,      default: 0
      t.string  :profile_pic_url
      t.string  :external_url
      t.boolean :is_verified, default: false
      t.datetime :last_scraped_at
      t.timestamps
    end
    add_index :ig_profiles, :username, unique: true

    create_table :ig_snapshots do |t|
      t.references :ig_profile, null: false, foreign_key: true
      t.integer :follower_count, default: 0
      t.integer :post_count,     default: 0
      t.date    :snapshot_date,  null: false
      t.timestamps
    end
    add_index :ig_snapshots, [:ig_profile_id, :snapshot_date], unique: true

    create_table :ig_posts do |t|
      t.references :ig_profile, null: false, foreign_key: true
      t.string  :shortcode, null: false
      t.text    :caption
      t.integer :likes,    default: 0
      t.integer :comments, default: 0
      t.datetime :posted_at
      t.timestamps
    end
    add_index :ig_posts, :shortcode, unique: true
  end
end
