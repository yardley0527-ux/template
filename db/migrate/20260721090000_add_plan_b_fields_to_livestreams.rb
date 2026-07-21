# frozen_string_literal: true

# 方案 B PR1：直播場次資料模型欄位（全部 additive，不動既有 registry 欄位）。
# reported_* = 歷史登記數字（來源見 db/data/livestream_reconciliation.yml，NULL＝無可信登記）；
# total_buyers / new_buyers / stats_refreshed_at = 推定檔期統計快取（PR3 的 RefreshService 寫入）。
class AddPlanBFieldsToLivestreams < ActiveRecord::Migration[7.1]
  def change
    change_table :livestreams, bulk: true do |t|
      t.string  :title
      t.integer :reported_orders
      t.decimal :reported_revenue, precision: 14, scale: 2
      t.integer :window_days, default: 3, null: false
      t.integer :total_buyers, default: 0, null: false
      t.integer :new_buyers, default: 0, null: false
      t.datetime :stats_refreshed_at
    end
  end
end
