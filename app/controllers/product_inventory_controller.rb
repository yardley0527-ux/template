# frozen_string_literal: true

# DANDY 產品庫存試算表的鏡像頁：保健品庫存總表＋按摩棒/藥盒每日異動。
# 資料由 DandyInventorySync 落地，這裡只讀最新快照。
class ProductInventoryController < ApplicationController
  def index
    SyncDandyInventoryJob.schedule_if_stale

    @snapshot = DandyInventorySnapshot.latest
    @last_run = SyncRun.latest_for("dandy_inventory")
  end
end
