class CreateSyncRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :sync_runs do |t|
      t.string :source, null: false
      t.string :status, null: false, default: "running"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.jsonb :error_messages, null: false, default: []
      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :sync_runs, [:source, :created_at]
  end
end
