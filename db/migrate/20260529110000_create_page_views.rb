class CreatePageViews < ActiveRecord::Migration[7.1]
  def change
    create_table :page_views do |t|
      t.string  :controller_name, null: false
      t.string  :action_name,     null: false
      t.string  :path
      t.integer :user_id
      t.datetime :visited_at,     null: false
    end

    add_index :page_views, :visited_at
    add_index :page_views, [:controller_name, :action_name]
  end
end
