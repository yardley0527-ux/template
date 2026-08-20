class AddLogisticsFieldsToReloveKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :relove_kocs, :logistics_notes, :text
    add_column :relove_kocs, :pr_gift_shipped_at, :date
  end
end
