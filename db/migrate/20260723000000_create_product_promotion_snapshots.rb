class CreateProductPromotionSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :product_promotion_snapshots do |t|
      t.string   :product_key,    null: false, limit: 50
      t.string   :product_name,   null: false, limit: 255
      t.string   :product_url,    null: false, limit: 500
      t.integer  :regular_price,  null: false
      t.integer  :sale_price,     null: false
      t.decimal  :discount_pct,   null: false, precision: 5, scale: 1
      t.datetime :scraped_at,     null: false

      t.timestamps
    end

    add_index :product_promotion_snapshots,
              [:product_key, :scraped_at],
              name: "idx_promotion_snapshots_on_product_scraped_at"
  end
end
