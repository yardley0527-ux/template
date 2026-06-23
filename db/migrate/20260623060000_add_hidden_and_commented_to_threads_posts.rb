class AddHiddenAndCommentedToThreadsPosts < ActiveRecord::Migration[7.1]
  def change
    add_column :threads_posts, :hidden, :boolean, default: false, null: false
    add_column :threads_posts, :commented, :boolean, default: false, null: false
    add_index :threads_posts, :hidden
  end
end
