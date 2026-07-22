class CreateTagExtractionRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :tag_extraction_runs do |t|
      t.date :range_start, null: false
      t.date :range_end, null: false
      t.integer :customer_count, null: false, default: 0
      t.jsonb :category_counts, null: false, default: {}
      t.timestamps
    end

    create_table :tag_extraction_recipients do |t|
      t.references :tag_extraction_run, null: false, foreign_key: true
      t.string :category, null: false
      t.string :email, null: false
      t.string :full_name
      t.string :line_id
      t.string :purchase_month
      t.timestamps
    end

    add_index :tag_extraction_recipients, [:tag_extraction_run_id, :category, :email],
              unique: true, name: "index_tag_extraction_recipients_on_run_category_email"
  end
end
