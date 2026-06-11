class CreateLivestreamGifts < ActiveRecord::Migration[7.1]
  def change
    create_table :livestream_gifts do |t|
      t.references :livestream, null: false, foreign_key: true
      t.string :description, null: false
      t.boolean :highlight, default: false, null: false
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
