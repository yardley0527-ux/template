class AddPaidAtToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :paid_at, :date
    add_column :kocs, :contract_completed, :boolean, default: false, null: false
  end
end
