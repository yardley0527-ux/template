class AddFirstBottlesToCustomerPurchaseSummaries < ActiveRecord::Migration[7.1]
  def change
    # 首購那筆訂單裡「首購系列」的付費瓶數（送的不算），客人資料庫用來標大組數
    add_column :customer_purchase_summaries, :first_bottles, :integer
  end
end
