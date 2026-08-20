class AddLogisticsNotesToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :logistics_notes, :text
  end
end
