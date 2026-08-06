class AddNextSameProductOrderToCrmCustomerProductCycles < ActiveRecord::Migration[7.1]
  def change
    # matched_next_order_number/date/product_key（既有欄位）代表「購買後第一筆
    # 任何產品的有效訂單」(next_any_order)。這裡新增的兩欄代表「購買後第一筆
    # 包含原產品的有效訂單」(next_same_product_order)——兩者刻意分開儲存，
    # 因為同一個週期可能同時發生跨品購買與之後的同品回購（Phase 1.5 修正：
    # 不能只看最早一筆訂單就判定最終結果）。
    add_column :crm_customer_product_cycles, :next_same_product_order_number, :string, limit: 100
    add_column :crm_customer_product_cycles, :next_same_product_order_date, :date
  end
end
