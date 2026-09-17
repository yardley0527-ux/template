class AddGroupBuyFieldsToIgPosts < ActiveRecord::Migration[7.1]
  def change
    add_column :ig_posts, :url, :string
    add_column :ig_posts, :hashtags, :text, array: true, default: [], null: false
    add_column :ig_posts, :mentions, :text, array: true, default: [], null: false
    add_column :ig_posts, :tagged_users, :text, array: true, default: [], null: false
    add_column :ig_posts, :product_type, :string
  end
end
