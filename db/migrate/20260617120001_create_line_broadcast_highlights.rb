class CreateLineBroadcastHighlights < ActiveRecord::Migration[7.1]
  def change
    create_table :line_broadcast_highlights do |t|
      t.datetime :push_time
      t.string :topic
      t.string :image_url, null: false
      t.string :cloudinary_public_id, null: false
      t.text :note
      t.decimal :revenue
      t.decimal :read_rate
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
