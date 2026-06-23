class AddMaxVideoViewsUrlToKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :max_video_views_url, :string
  end
end
