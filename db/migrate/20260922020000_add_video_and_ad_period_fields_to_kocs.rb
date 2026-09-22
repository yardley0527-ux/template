class AddVideoAndAdPeriodFieldsToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :video_posted_at, :date
    add_column :kocs, :ad_start_at, :date
    add_column :kocs, :ad_end_at, :date
  end
end
