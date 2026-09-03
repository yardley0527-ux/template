class CreateKolQuoteItems < ActiveRecord::Migration[7.1]
  def change
    create_table :kol_quote_items do |t|
      t.references :kol_candidate, null: false, foreign_key: true
      t.string :item_name, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.boolean :tax_included, null: false, default: false
      t.string :period
      t.text :notes

      t.timestamps
    end
  end
end
