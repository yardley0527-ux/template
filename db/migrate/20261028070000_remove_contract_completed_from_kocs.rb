class RemoveContractCompletedFromKocs < ActiveRecord::Migration[7.1]
  def change
    remove_column :kocs, :contract_completed, :boolean, default: false, null: false
  end
end
