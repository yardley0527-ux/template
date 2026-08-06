# 回購提醒（CRM Repurchase）上線部署文件

涵蓋 Phase 1–4.1：回購週期資料層、回購追蹤 Dashboard、直播回購候選名單、客服排程與每日任務。

## 1. 部署前檢查

在正式站執行以下唯讀檢查前，先確認 `DATABASE_URL` 指向正式 DB 且已備份（依既有部署流程）。

```bash
RAILS_ENV=production bin/rails crm_repurchase:preflight
```

- 輸出 0 個 🛑 BLOCKER 才可繼續部署；⚠️ WARNING 可上線但需留意（見下方「已知 WARNING」）。
- 此指令**不會寫入任何資料**（`CrmRepurchasePreflightCheck` 僅查詢，`refresh_capability_check` 只做結構檢查，不實際執行 refresh）。

## 2. Migration 執行順序

本次新增 7 個 migration（皆已通過 up/down/up 驗證）：

```
20260804180000  create_crm_repurchase_cycle_configs
20260804180001  create_crm_customer_product_cycles
20260805090000  add_next_same_product_order_to_crm_customer_product_cycles
20260805100000  add_follow_up_fields_to_crm_customer_product_cycles
20260805100001  create_crm_customer_product_follow_up_events
20260806090000  add_livestream_id_to_crm_customer_product_follow_up_events
20260807090000  create_crm_livestream_outreach_tasks
```

```bash
RAILS_ENV=production bin/rails db:migrate
```

無需額外的 `db:schema:load`；正式站是既有資料庫，用一般 `db:migrate` 依序套用即可。

## 3. Preflight 指令

部署後、開放使用者存取前，再跑一次確認狀態：

```bash
RAILS_ENV=production bin/rails crm_repurchase:preflight
```

## 4. Product Registry Alias / Bootstrap 同步

正式站的 `crm_products.sql_pattern` 與 `CrmProductAlias` 需先同步，否則榖胱甘肽／益生箘等別名拼法的訂單不會被納入週期計算（Phase 5 發現並修正的根因）：

```bash
RAILS_ENV=production bin/rails product_registry:bootstrap
```

- 冪等：已存在的 CrmProduct/pattern 不會被覆蓋，只補齊缺的部分。
- 若正式站已完整跑過 Product Registry 相關流程，此步驟為 no-op 確認用。

## 5. 產品週期 Seed 指令

```bash
RAILS_ENV=production bin/rails crm_repurchase_cycle_configs:seed
```

- 冪等：13 個旅程管理產品（排除面膜）的回購週期天數設定，已存在的不會被覆蓋。

## 6. Cycle Refresh 指令

初次上線需建立約 4 萬筆歷史顧客×產品×週期資料（**這是資料建置，非 migration**，需另外手動執行，且耗時較長，建議在離峰時段跑）：

```bash
RAILS_ENV=production bin/rails crm_customer_product_cycles:refresh_all
```

之後的排程 refresh（例如接到日常 cron）用同一指令即可，服務內建 upsert 邏輯會保留手動覆蓋欄位。

## 7. PagePermission 設定

正式站目前預期只有管理者（`current_user.admin?`）可存取新頁面。若要開放特定客服角色使用「我的今日任務」等頁面，需手動建立 `PagePermission`：

```ruby
role = Role.find_by!(key: "客服角色key")
PagePermission.create!(role: role, controller_name: "crm_outreach_tasks")
# 依需要開放的頁面，controller_name 可為：
#   crm_repurchase_follow_ups       (回購追蹤 Dashboard)
#   livestream_repurchase_candidates (直播回購候選名單)
#   crm_livestream_schedules        (排程預覽/建立)
#   crm_outreach_tasks              (我的今日任務)
```

Sidebar 入口會依 `SidebarEntry.visible_for` 自動依權限顯示/隱藏，不需另外設定。

## 8. Livestream product_keys 設定

直播回購候選名單只會針對「已在該場直播設定 `product_keys`」的直播產生候選名單。上線前確認即將舉辦的直播已設定：

```ruby
livestream = Livestream.find(...)
livestream.update!(product_keys: ["product_key_a", "product_key_b"])
```

`crm_repurchase:preflight` 的「已設定 product_keys 的未來直播」項目可用來確認漏設的場次。

## 9. 冰晶番茄人工週期設定

冰晶番茄目前刻意沒有 `CrmRepurchaseCycleConfig`（非既有回購週期產品），Phase 4/5 已確認全頁面對此情境做了 nil-safety 處理（不顯示估算天數、不會拋錯、不會被排入候選名單）。**若未來業務決定要追蹤此產品的回購週期**，需手動新增設定：

```ruby
CrmRepurchaseCycleConfig.create!(product_key: "iced_tomato_product_key", bottle_count: 1, median_days: ..., source: "manual")
```

新增後執行 `crm_customer_product_cycles:refresh[iced_tomato_product_key]` 才會產生對應週期資料。上線當下**不需要**執行此步驟。

## 10. 正式站抽查方式

部署完成後，以管理者帳號登入正式站人工抽查（唯讀操作，不建立正式排程、不送出訊息）：

1. `crm_repurchase:preflight` 顯示 0 BLOCKER。
2. 開啟「回購追蹤 Dashboard」，確認列表與 KPI 卡數字一致、可正常分頁。
3. 開啟「直播回購候選名單」，挑一場已設定 `product_keys` 的未來直播，確認候選名單分類（replenish/win_back）與人數合理。
4. 開啟「排程預覽」（`new`/`preview`），確認 preview 頁不寫入資料庫（可用 `CrmLivestreamOutreachTask.count` 前後比對）。
5. 開啟「我的今日任務」，以非管理者帳號確認只看得到自己的任務；以管理者帳號確認看得到全部。
6. 確認冰晶番茄相關列不會讓任何頁面報錯。

## 11. Rollback 條件與步驟

**觸發條件**：preflight 出現 BLOCKER、`refresh_all` 造成資料庫效能異常、或任一新頁面在正式站出現無法即時修復的錯誤。

**步驟**：

1. 若只是資料問題（例如 refresh 產生錯誤資料），優先用既有 upsert 機制重跑 `crm_customer_product_cycles:refresh_all` 修正，不需要 rollback migration（cycle 表格是可重建的快取，不是原始資料）。
2. 若需要完整回滾 schema：

   ```bash
   RAILS_ENV=production bin/rails db:rollback STEP=7
   ```

   本地已驗證此 7 個 migration 可乾淨互相 down/up，不會影響既有資料表（`shopline_customers`／`shopline_orders`／既有 `livestreams` 欄位皆未被本次改動觸碰，只新增獨立資料表與 `crm_customer_product_follow_up_events.livestream_id`／`crm_livestream_outreach_tasks` 對 `livestreams` 的外鍵關聯）。
3. Rollback 後，隱藏或移除相關 `PagePermission`／sidebar 入口存取（若已開放給客服角色）。
4. 回滾不影響 `CrmProduct`／`CrmProductAlias`（Product Registry 既有資料表，非本次新增），無需額外處理。

## 已知 WARNING（上線時預期會看到，非阻塞）

- 缺週期設定產品名稱：冰晶番茄（見第 9 節，刻意不設定）。
- 無法辨識產品：9 筆（如「維生素D3K2+海藻鈣」等，人工判斷後保留待未來確認，不可自行猜測合併）。
- 數量含糊：52 筆（私密粉／魚油等未來需擴充 regex 才能精準判斷數量，本輪僅報告不處理）。
- 客服 PagePermission：預設只有管理者可存取，需依第 7 節手動開放給客服角色。
