# frozen_string_literal: true

# DANDY 產品庫存試算表的鏡像頁：保健品庫存總表＋按摩棒/藥盒每日異動。
# 資料由 DandyInventorySync 落地，這裡只讀最新快照。
class ProductInventoryController < ApplicationController
  # 叫貨行動時程：人工分析（2026-08-17 建立，2026-08-17 依第二批「美白/清纖粉/
  # 私密粉/蝦紅素/維生素D/益生菌/穀胱甘肽/冰晶番茄/魚油/日本關節PDRN」進貨表
  # 截圖＋使用者口頭提供的代謝錠到貨日擴充），比對 shopline_orders 實際銷售與
  # crm_products 庫存狀態得出，不是任何表格的即時查詢結果。日期異動要手動更新
  # 這裡。on_chart: true 的項目會畫在頁面上方的 SVG 時間軸（範圍固定在 7/15–
  # 8/31，代謝錠 10/12 月的到貨日超出這個範圍，只出現在清單）。
  PURCHASING_ACTION_PLAN = [
    {
      product: "全能 B群", icon: "🔴", status: :urgent, when: "立即", on_chart: true,
      action: "確認供應商到貨日並下單叫貨",
      reason: "現貨 0、無到貨日排程。6月清倉衝出單月817張訂單／867萬營收後，7-8月業績已經掛零" \
              "（7月僅3張訂單、8月至今掛零）——還沒排到貨日的產品線之一"
    },
    {
      product: "維生素D（維DK鈣）", icon: "🔴", status: :urgent, when: "立即", on_chart: true,
      action: "跟供應商確認已下訂單 3,000 的到貨日，並在系統補登",
      reason: "5月之後訂單完全掛零，已斷貨3個多月。已下訂單3,000，但目前系統裡沒有到貨日，" \
              "跟全能B群一樣是「有訂但不知道何時到」的狀態"
    },
    {
      product: "美白", icon: "🔴", status: :urgent, when: "立即", on_chart: true,
      action: "跟供應商確認已下訂單 3,000 的到貨日，並在系統補登",
      reason: "H1 營收年減 94.7%（716萬→38萬），5月後訂單掛零。已下訂單3,000但同樣沒有到貨日"
    },
    {
      product: "蝦紅素", icon: "🟠", status: :scheduled, when: "8/21", on_chart: true,
      action: "到貨，並到 /product_registry 更新庫存狀態",
      reason: "DANDY 庫存顯示即時庫存僅剩 1 件，H1 營收年減 70%（417萬→125萬）。8/21 已排定到貨，" \
              "比膠原蛋白晚一天"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/20", on_chart: true,
      action: "到貨，並到 /product_registry 把狀態改成「有貨」、填入實際到貨日",
      reason: "已斷貨3個多月（5月後訂單掛零），2026年完全沒有進貨記錄，H1 營收年減 71.5%"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/20–8/21", on_chart: true,
      action: "對斷貨期間流失的客戶名單發送回購喚回通知，不要等自然回溫",
      reason: "買家數從 H1-2025 的 1,492 人掉到 H1-2026 只剩 338 人，光靠上架不會把人找回來"
    },
    {
      product: "膠原蛋白", icon: "🟠", status: :scheduled, when: "8/23（到貨+3天）", on_chart: true,
      action: "檢查是否已上架、有無零銷售",
      reason: "系統的「到貨3天仍零銷售」告警規則要等狀態改成有貨＋填入到貨日才會生效，到貨後記得先完成上一步"
    },
    {
      product: "代謝錠", icon: "🟠", status: :scheduled, when: "10月中", on_chart: false,
      action: "到貨 3,000",
      reason: "已排定下一輪叫貨，現貨足夠撐到10月；不在本頁時間軸範圍內（軸只畫到8/31）"
    },
    {
      product: "代謝錠", icon: "🟠", status: :scheduled, when: "12月中", on_chart: false,
      action: "到貨 3,000",
      reason: "第二輪叫貨，銜接年底旺季備貨；不在本頁時間軸範圍內（軸只畫到8/31）"
    },
    {
      product: "私密粉", icon: "🟡", status: :plan_ahead, when: "近期", on_chart: true,
      action: "排下一輪叫貨",
      reason: "現貨442、H1賣出424張訂單，去化速度接近1:1，目前沒有已下訂單記錄"
    },
    {
      product: "穀胱甘肽", icon: "🟡", status: :plan_ahead, when: "待確認", on_chart: false,
      action: "跟供應商確認已下訂單 4,000 的到貨日，並在系統補登庫存狀態",
      reason: "新品持續成長（H1 營收734萬），已下單4,000但無到貨日；系統庫存狀態仍是「未確認」"
    },
    {
      product: "冰晶番茄", icon: "🟡", status: :plan_ahead, when: "持續觀察", on_chart: false,
      action: "在系統補登庫存狀態",
      reason: "新品剛起步（H1 營收163萬，持續有訂單），系統庫存狀態尚未確認"
    },
    {
      product: "日本關節PDRN", icon: "🟡", status: :plan_ahead, when: "上市後", on_chart: false,
      action: "留意首波銷售，確保已下訂單 2,500 如期到貨",
      reason: "全新品項，尚無歷史銷售資料，已下訂單2,500"
    },
    {
      product: "清纖粉", icon: "🟢", status: :reference, when: "—", on_chart: false,
      action: "維持正常進貨節奏",
      reason: "現貨1,020，H1營收450萬已接近2025全年535萬，銷售穩定"
    },
    {
      product: "益生菌", icon: "🟢", status: :reference, when: "—", on_chart: false,
      action: "維持正常進貨節奏",
      reason: "新品健康成長（H1營收631萬），現貨1,493尚足"
    },
    {
      product: "魚油", icon: "🟢", status: :reference, when: "—", on_chart: false,
      action: "維持正常進貨節奏",
      reason: "7/14剛到貨（現貨1,995），持續觀察去化速度"
    },
    {
      product: "薑黃", icon: "🟢", status: :reference, when: "已完成（7/15 到貨）", on_chart: true,
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
