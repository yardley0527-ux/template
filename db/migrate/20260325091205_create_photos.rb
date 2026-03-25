class CreatePhotos < ActiveRecord::Migration[7.1]
  def change
    create_table :photos do |t|
      t.references :album, null: false, foreign_key: true
      t.string :cloudinary_public_id, null: false
      t.string :url, null: false
      t.string :caption
      t.integer :position, default: 0

      t.timestamps
    end
    add_index :photos, [:album_id, :position]
  end
end