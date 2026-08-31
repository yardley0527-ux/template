class AddLiveAdsFieldsToLivestreams < ActiveRecord::Migration[7.1]
  def change
    add_column :livestreams, :platform, :string
    add_column :livestreams, :link_keyword, :string
    add_column :livestreams, :start_time, :string
    add_column :livestreams, :end_time, :string
    add_column :livestreams, :ran_ads, :boolean, default: false, null: false
    add_column :livestreams, :ad_approved_time, :string
    add_column :livestreams, :ad_spend, :decimal, precision: 12, scale: 2, default: "0.0", null: false
    add_column :livestreams, :viewers_entry, :integer
    add_column :livestreams, :viewers_peak, :integer
    add_column :livestreams, :viewers_end, :integer

    add_index :livestreams, :platform
  end
end
