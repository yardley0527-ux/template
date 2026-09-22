class AddContractFieldsToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :contract_sent_at, :date
    add_column :kocs, :contract_received_at, :date
  end
end
