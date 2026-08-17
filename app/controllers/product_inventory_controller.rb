# frozen_string_literal: true

# DANDY 產品庫存試算表的鏡像頁：保健品庫存總表＋按摩棒/藥盒每日異動。
# 資料由 DandyInventorySync 落地，這裡只讀最新快照。
class ProductInventoryController < ApplicationController
  # 叫貨行動時程：人工分析（2026-08-17，比對「2025 vs 2026 進貨/營收同期比較表」
  # 截圖與 shopline_orders 實際銷售/crm_products 庫存狀態得出），不是任何表格的
  # 即時查詢結果。膠原蛋白 8/20 到貨日是使用者 2026-08-17 口頭確認，若日期異動
  # 要手動更新這裡。
  PURCHASING_ACTION_PLAN = [
    {
      product: "全能 B群", icon: "🔴", status: :urgent, when: "立即",
      action: "確認供應商到貨日並下單叫貨",
      reason: "現貨 0、無到貨日排程。6月清倉衝出單月817張訂單／867萬營收後，7-8月業績已經掛零" \
              "（7月僅3張訂單、8月至今掛零）——4條產品線中唯一還沒排到貨日的"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/20",
      action: "到貨，並到 /product_registry 把狀態改成「有貨」、填入實際到貨日",
      reason: "已斷貨3個多月（5月後訂單掛零），2026年完全沒有進貨記錄，H1 營收年減 71.5%"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/20–8/21",
      action: "對斷貨期間流失的客戶名單發送回購喚回通知，不要等自然回溫",
      reason: "買家數從 H1-2025 的 1,492 人掉到 H1-2026 只剩 338 人，光靠上架不會把人找回來"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/23（到貨+3天）",
      action: "檢查是否已上架、有無零銷售",
      reason: "系統的「到貨3天仍零銷售」告警規則要等狀態改成有貨＋填入到貨日才會生效，到貨後記得先完成上一步"
    },
    {
      product: "代謝錠", icon: "🟡", status: :plan_ahead, when: "本月內",
      action: "提前排下一輪叫貨",
      reason: "現貨 1,385 尚可維持，但進貨量砍最兇（-68%），照月均 200–400 張訂單的消耗速度，" \
              "不提前排貨容易重演全能／膠原蛋白斷貨的情況"
    },
    {
      product: "薑黃", icon: "🟢", status: :reference, when: "已完成（7/15 到貨）",
      action: "維持正常進貨節奏即可，作為佐證案例",
      reason: "6-7月斷貨掛零，7/15到貨後8月單月噴出614張訂單、790萬營收——" \
              "直接證明「缺貨=業績歸零，補貨=業績立刻回來」"
    }
  ].freeze

  def index
    SyncDandyInventoryJob.schedule_if_stale

    @snapshot = DandyInventorySnapshot.latest
    @last_run = SyncRun.latest_for("dandy_inventory")
    @purchasing_plan = PURCHASING_ACTION_PLAN
  end
end
