class CreateCustomerSeriesLoyalties < ActiveRecord::Migration[7.1]
  def change
    create_table :customer_series_loyalties do |t|
      t.string  :email,           null: false
      t.string  :series,          null: false
      t.integer :order_count,     null: false, default: 0
      t.decimal :total_amount,    precision: 10, scale: 2, default: 0
      t.date    :first_date
      t.date    :last_date
      t.integer :days_since_last
      t.string  :tier

      t.timestamps
    end

    add_index :customer_series_loyalties, [:email, :series], unique: true
    add_index :customer_series_loyalties, :series
    add_index :customer_series_loyalties, :tier
  end
end