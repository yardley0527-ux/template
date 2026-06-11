class CreateLivestreamProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :livestream_products do |t|
      t.references :livestream, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :price, null: false
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
