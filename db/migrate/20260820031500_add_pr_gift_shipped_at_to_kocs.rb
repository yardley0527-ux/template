class AddPrGiftShippedAtToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :pr_gift_shipped_at, :date
  end
end
