# frozen_string_literal: true

# 老闆送給客人的公關品紀錄。一次送一筆，不綁訂單（跟 order_gift_records 的
# 「訂單贈品」是不同東西），也不會被算進客人購買的瓶數。
class CreatePrGifts < ActiveRecord::Migration[7.1]
  def change
    create_table :pr_gifts do |t|
      t.references :shopline_customer, null: false, foreign_key: true
      t.string  :product_name, null: false
      t.integer :quantity,     null: false, default: 1
      t.string  :unit,         null: false, default: "瓶"
      t.date    :given_on,     null: false
      t.string  :note
      t.string  :created_by
      t.timestamps
    end

    add_index :pr_gifts, %i[shopline_customer_id given_on]
  end
end
