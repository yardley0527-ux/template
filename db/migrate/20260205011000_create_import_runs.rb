# path: db/migrate/20260205011000_create_import_runs.rb
class CreateImportRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :import_runs do |t|
      t.string :kind, null: false
      t.string :file_name, null: false
      t.string :file_checksum, null: false
      t.jsonb :meta, null: false, default: {}
      t.integer :processed_rows, null: false, default: 0
      t.integer :upserted_rows, null: false, default: 0
      t.integer :skipped_rows, null: false, default: 0
      t.integer :error_rows, null: false, default: 0
      t.jsonb :errors, null: false, default: []
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :import_runs, [:kind, :file_checksum]
  end
end
