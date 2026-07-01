class AddGrowthTrendToCustomerSeriesLoyalties < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_series_loyalties, :first_half_avg_amount, :decimal, precision: 10, scale: 2
    add_column :customer_series_loyalties, :second_half_avg_amount, :decimal, precision: 10, scale: 2
    add_column :customer_series_loyalties, :growth_rate_pct, :decimal, precision: 6, scale: 1
    add_column :customer_series_loyalties, :is_growing, :boolean, null: false, default: false

    add_index :customer_series_loyalties, :is_growing
  end
end
