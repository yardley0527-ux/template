class CreateLivestreamImages < ActiveRecord::Migration[7.1]
  def change
    create_table :livestream_images do |t|
      t.references :livestream, null: false, foreign_key: true
      t.string :cloudinary_public_id, null: false
      t.string :url, null: false
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
