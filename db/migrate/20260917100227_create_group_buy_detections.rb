class CreateGroupBuyDetections < ActiveRecord::Migration[7.1]
  def change
    create_table :group_buy_detections do |t|
      t.references :ig_post, null: false, foreign_key: true, index: { unique: true }
      t.boolean :is_group_buy, default: false, null: false
      t.integer :confidence, default: 0, null: false
      t.text :matched_keywords, array: true, default: [], null: false
      t.string :detected_brand
      t.string :detected_product_name
      t.string :status, default: "待確認", null: false
      t.text :note

      t.timestamps
    end
    add_index :group_buy_detections, :status
  end
end
