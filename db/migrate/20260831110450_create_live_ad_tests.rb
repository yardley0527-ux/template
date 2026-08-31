class CreateLiveAdTests < ActiveRecord::Migration[7.1]
  def change
    create_table :live_ad_tests do |t|
      t.date :date, null: false
      t.string :platform
      t.string :product
      t.string :link_keyword
      t.string :start_time
      t.string :end_time
      t.boolean :ran_ads, default: false, null: false
      t.string :ad_approved_time
      t.decimal :ad_spend, precision: 12, scale: 2, default: "0.0", null: false
      t.integer :viewers_entry
      t.integer :viewers_peak
      t.integer :viewers_end
      t.integer :orders, default: 0, null: false
      t.decimal :revenue, precision: 12, scale: 2, default: "0.0", null: false
      t.text :notes

      t.timestamps
    end

    add_index :live_ad_tests, :platform
    add_index :live_ad_tests, :date
  end
end
