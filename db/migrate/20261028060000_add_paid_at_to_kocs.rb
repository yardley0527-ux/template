class AddPaidAtToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :paid_at, :date
  end
end
