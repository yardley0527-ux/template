class CreateIgReviewItems < ActiveRecord::Migration[7.1]
  def change
    create_table :ig_review_items do |t|
      t.string :source_key, null: false
      t.string :kind, null: false
      t.string :severity
      t.text :title, null: false
      t.jsonb :detail, null: false, default: {}
      t.string :event_codes, array: true, null: false, default: []
      t.string :customer_name
      t.string :customer_email
      t.date :as_of
      t.string :status, null: false, default: "open"
      t.text :note
      t.bigint :handled_by_user_id
      t.datetime :handled_at
      t.timestamps
    end
    add_index :ig_review_items, :source_key, unique: true
    add_index :ig_review_items, [:kind, :status]
  end
end
