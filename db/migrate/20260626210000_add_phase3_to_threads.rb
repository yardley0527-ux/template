class AddPhase3ToThreads < ActiveRecord::Migration[7.1]
  def change
    add_column :threads_posts, :interaction_score,  :integer, default: 0, null: false
    add_column :threads_posts, :matched_keywords,   :string,  array: true, default: [], null: false
    add_column :threads_posts, :matched_categories, :string,  array: true, default: [], null: false
    add_index  :threads_posts, :interaction_score

    create_table :threads_fetch_logs do |t|
      t.string   :category,       null: false
      t.string   :search_queries, array: true, default: [], null: false
      t.datetime :fetched_at,     null: false
      t.integer  :result_count,   default: 0, null: false
      t.string   :status,         default: "success", null: false
      t.timestamps
    end
    add_index :threads_fetch_logs, [:category, :fetched_at]
  end
end
