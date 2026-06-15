class CreateThreadsAnalyses < ActiveRecord::Migration[7.1]
  def change
    create_table :threads_analyses do |t|
      t.date :fetched_on, null: false
      t.text :ai_summary
      t.jsonb :stats_json, default: []
      t.timestamps
    end
    add_index :threads_analyses, :fetched_on, unique: true
  end
end
