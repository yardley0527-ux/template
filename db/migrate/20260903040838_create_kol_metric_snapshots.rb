class CreateKolMetricSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :kol_metric_snapshots do |t|
      t.references :kol_candidate, null: false, foreign_key: true
      t.string :platform, null: false
      t.integer :followers_count
      t.integer :following_count
      t.integer :posts_count
      t.decimal :engagement_rate, precision: 6, scale: 3
      t.integer :avg_views
      t.integer :avg_likes
      t.string :source, null: false, default: "manual"
      t.datetime :fetched_at, null: false
      t.jsonb :raw_data, null: false, default: {}

      t.timestamps
    end
  end
end
