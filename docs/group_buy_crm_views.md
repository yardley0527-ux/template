# group-buy-crm 唯讀 View（smartadmin 端）

給獨立的 **group-buy-crm** 應用程式讀取苼莛會員資料用。它**不複製任何會員資料**，只透過三個唯讀 View 讀取；View 與唯讀 role 都在 smartadmin 這一側維護。

> 狀態：階段 1（本機開發完成）。**尚未在正式站執行 migration、尚未建立正式站 role、尚未部署。** 正式站執行前的確認項目見文末。

## 1. 架構

```
group-buy-crm ──(專用唯讀 role: group_buy_crm_ro)──▶  schema group_buy_crm
                                                        ├─ members                    (View 1)
                                                        ├─ member_order_lines         (View 2, canonical 訂單商品)
                                                        └─ member_product_summaries   (View 3)
                                                              │ 以擁有者權限讀取
                                                              ▼
                                       shopline_customers / shopline_orders / customer_profiles /
                                       product_name_mappings / product_mapping_components / crm_products
```

- View 以**擁有者權限**執行（不加 `security_invoker`），所以唯讀 role **對原始資料表沒有任何權限**。
- 商品對應、bundle 展開、購買次數、訂單去重的規則**只在這裡**（smartadmin）維護，group-buy-crm 只讀取與顯示。

## 2. 檔案

| 檔案 | 用途 |
|---|---|
| `db/views/group_buy_crm_*_v01.sql` | 三個 View 的 SELECT（Scenic 管理，全部 schema-qualified） |
| `db/migrate/20260919110000_create_group_buy_crm_readonly_views.rb` | 建立 schema 與 View；role 已存在時才 GRANT |
| `db/ops/group_buy_crm_readonly_role.sql` | **手動**建立唯讀 role 與授權（不在 migration 內） |
| `db/ops/verify_group_buy_crm_readonly_role.sh` | 以該 role 真實登入的權限驗證（PASS／FAIL／WARN） |
| `test/db/group_buy_crm_*_test.rb` | 契約、語意、與既有 Ruby 邏輯的一致性測試 |

## 3. View 欄位（契約；新增或刪除欄位必須同時修改測試與 group-buy-crm）

**`group_buy_crm.members`**：`shopline_customer_id`、`shopline_id`、`name`、`email`、`normalized_email`、`membership_level`、`total_amount`、`blacklisted`、`membership_expiry_date`、`joined_at`、`credits`、`points`、`last_order_date`

**`group_buy_crm.member_order_lines`**（一列 = 一筆 canonical 訂單商品）：`order_line_key`、`shopline_customer_id`、`customer_link_source`、`email_consistent`、`order_number`、`order_date`、`raw_product_name`、`mapping_status`、`mapping_candidate_count`、`product_key`、`product_label`、`bundle_component_keys`、`line_quantity`、`source_line_count`

**`group_buy_crm.member_product_summaries`**（一列 = 會員 × 商品）：`shopline_customer_id`、`product_key`、`product_label`、`mapping_status`、`order_count`、`first_order_date`、`last_order_date`

不含電話、地址、生日、金額（除 `total_amount`）、付款方式、UTM、備註等；測試會擋。

## 4. 規則

**會員**
- `total_amount` 直接取 `shopline_customers.total_amount`，NULL 就是 NULL，View 不重算、不補值。它與訂單去重加總目前**存在差異**（開發資料約 18% 不一致）；group-buy-crm 第一階段以它為唯一顯示來源。未來若要校正，應由 smartadmin 的會員資料層統一處理，**不要由 group-buy-crm 自行修正**。
- `membership_level` 原樣傳遞（NULL 不視為一般會員）；`is_member` 欄位不可用，View 不提供。
- `blacklisted` = `shopline_customers.blacklisted` 為真，**或**任一 `customer_profiles.blacklisted` 為真（用 `EXISTS`，NULL 視為 false；`customer_profiles` 沒有唯一索引，用 JOIN 會讓會員重複）。

**Email 正規化**（View 1、View 2 與 group-buy-crm 必須一致）：去除首尾空白（含全形 U+3000）、移除零寬字元（U+200B–U+200D、U+2060、U+FEFF）、轉小寫；**不動** Gmail 的點與加號、不動網域。

> **View SQL 內不可放原始控制字元**（CR／TAB 等）。Scenic 會把 View 定義原樣寫進 `db/schema.rb`，Ruby 讀入 heredoc 時會吞掉字面的 CR，於是 `schema:load` 與 `migrate` 建出不同的 View（曾實際發生：test DB 少 trim 一個 `\r`）。所以 trim 字元集用 `chr(9)`、`chr(10)`、`chr(13)`、`chr(12288)` 組成；`test/db/group_buy_crm_views_contract_test.rb` 有 round-trip 測試（dump／load 後定義必須逐字相同）與「定義內無控制字元」測試。

**訂單商品（View 2）**
1. 基準：`ShoplineOrder.valid_paid` + `dedup_content_drift`（語意等價，改用 window 表達，見 §6）。`quantity`／`checkout_amount` 為 NULL 的列、`import_run_id` 為 NULL 且同群組商品名不同的列，會與現有 scope 一樣被排除。
2. canonical 化：同 `(order_number, 原始商品名)` 只保留**最新匯入批次**（`import_run_id` 最大）那批列；同批內合理的重複品項保留，`line_quantity`（**訂購份數**，不是瓶數）為其加總。
3. `order_line_key` = `jsonb_build_array(order_number, product_name)::text`：單射編碼，不同組合一定得到不同字串（含 `|`、換行、引號、Unicode 皆可），不經過 hash 所以無碰撞；相同組合永遠相同 key，與匯入批次無關。View 內唯一。
4. 會員歸屬：訂單上有效的 `shopline_customer_id` 優先（`customer_link_source = 'order_customer_id'`）；為 NULL 時，只有**正規化 Email 唯一對到一位會員**才補（`'unique_email'`）；零筆、多筆、或同一訂單商品出現兩個不同 id → 不歸屬（NULL）。id 有效但訂單 Email 與會員不一致 → 仍歸該會員，`email_consistent = false`。id 指向不存在的會員 → 不歸屬，且**不**用 Email 偷補。
5. 商品對應 `mapping_status`：
   - `mapped`：該 `raw_name` 恰有 1 筆 `confirmed_alias` 且有商品 → 套用；
   - `unmapped`：沒有 `confirmed_alias`（含 `ignored`、`pending`、confirmed 但沒有商品）；
   - `conflict`：**多筆** `confirmed_alias` → **不套用任何一筆**，`product_key`／`product_label` 為 NULL，保留 `raw_product_name`，`mapping_candidate_count` 為候選數。多筆即使指向同一商品也標 `conflict`（fail-safe，不猜）。
   - 現有唯一索引只有 `(raw_name, source)`，**資料庫並不禁止**同名多筆 confirmed，所以 conflict 是真實可能發生的狀況。
6. `bundle_component_keys` 只有 `mapped` 才有（與 `ProductNameResolver.orders_for` 的元件路徑同來源）。

**商品彙總（View 3）**：購買次數 = `COUNT(DISTINCT order_number)`（同訂單被 primary／component 多路徑命中只算一次；用 `COUNT(*)` 會多算）。`unmapped` 與 `conflict` 各自以 `raw:<原始名稱>` 獨立成列，**不併入任何商品**。

**第一階段刻意不提供**：彙總數量、瓶數、贈品數。理由：訂單列的 `quantity` 是「份數」，單位隨商品名稱不同；付款／贈品拆解在 Ruby 的 `ProductQuantityParserService`，寫入 component 的分支尚未合併，`paid_quantity`／`gift_quantity` 的預設值（1／0）與「尚未解析」無法區分。

## 5. Scenic 設定

- `gem 'scenic', '~> 1.9'`（鎖定 1.9.0）。
- `config/database.yml` 的 **development 與 test** 加了 `schema_search_path: "public,group_buy_crm"`。原因（已實測）：Scenic 只 dump `search_path` 內的 schema，且 `pg_get_viewdef` 會省略 `search_path` 內物件的 schema 前綴，所以載入 `db/schema.rb` 時 `search_path` 也必須含 `group_buy_crm`，否則 `relation "member_order_lines" does not exist`（會大聲失敗，不會靜默）。production 不載入 `schema.rb`，不需要、也刻意沒有設定。
- `db/schema.rb` 會多出 `create_schema "group_buy_crm"` 與三個 `create_view`（約 230 行）。這是 Scenic 依資料庫自動產生的定義，**不要手動編輯**。
- 修改 View：新增 `..._v02.sql` 並用 `update_view`，不要直接改 `_v01`。
- 退路：若不想動 `database.yml`，View 可改放 public 並加前綴（`group_buy_crm_members` 等），Scenic 不需任何設定。

## 6. 效能（重要，請勿改回舊寫法）

第一版 View 用 `GROUP BY` + `IS NOT DISTINCT FROM` self-join 做去重、用 `JOIN` 做 Email 唯一候選；window 過濾後 planner 把列數估成 1～2，選了巢狀迴圈，實測 **20～55 秒**（View 3 逾時），會超過 role 的 `statement_timeout = 15s`。現在的寫法（`drift` 改 window、唯一候選改「訂單列＋會員疊在一起、`PARTITION BY` 正規化 Email」）：

| 查詢（開發 DB：10,262 會員／39,759 canonical 列／21,232 彙總列） | 耗時 |
|---|---|
| 用 Email 找會員（`members`） | ~6 ms |
| 單一會員商品摘要（`member_product_summaries`） | ~0.25 s |
| 單一會員最近 10 筆訂單商品（`member_order_lines`） | ~0.22 s |
| `member_order_lines` 全表 count | ~0.14 s |
| `member_product_summaries` 全表 count | ~0.30 s |

已知：View 2 需要整批計算 canonical 列，所以單一會員查詢也是 ~0.2 秒（與資料量成正比，不是與會員數）。若正式站資料量大很多，才需要評估改成 materialized view（Scenic 支援，但需要在匯入後 refresh）。

## 7. 唯讀 role

1. 先跑 migration（建立 View）。
2. 以資料庫擁有者執行 `db/ops/group_buy_crm_readonly_role.sql`（`CREATE ROLE`、設定、`GRANT`）。
3. 用 `\password group_buy_crm_ro` 互動設定密碼（client 端加密；密碼不進 migration、repo、log、shell history）。
4. 驗證：`GROUP_BUY_CRM_RO_URL=… db/ops/verify_group_buy_crm_readonly_role.sh`（連線字串放環境變數）。所有寫入嘗試都包在 `READ WRITE` 交易並 `ROLLBACK`，即使權限真的漏了也不會留下東西。

Role 設定：`search_path = group_buy_crm, pg_catalog`、`default_transaction_read_only = on`、`statement_timeout = 15s`、`idle_in_transaction_session_timeout = 30s`、`CONNECTION LIMIT 5`。**整個資料庫中只擁有** `group_buy_crm` 的 `USAGE` 與三個 View 的 `SELECT`。

**軟保險的極限**：`default_transaction_read_only` 是 role 自己可以關掉的預設值。在 PostgreSQL 14 以前，`public` schema 預設讓 PUBLIC 可以建表，所以 role 關掉 read-only 後仍可 `CREATE TABLE public.x`（驗證腳本會以 `WARN` 標出，且會 ROLLBACK）。要成為硬保證，請另行評估並執行 `db/ops/group_buy_crm_readonly_role.sql` 末段的兩條 `REVOKE`（只影響非擁有者的 role；已在本機驗證有效，套用後驗證腳本 `WARN` 歸零）。

## 8. 測試

`bin/rails test test/db`（56 個測試）：契約（欄位精確、無個資欄位、無 `security_invoker`、全部 schema-qualified、`schema.rb` 內容、**dump／load round-trip 定義逐字相同**、定義內無原始控制字元、migration up／down 可逆、role 存在時的 GRANT 範圍）、去重與 canonical、`order_line_key`（含碰撞案例與特殊字元）、mapping 0／1／多筆、Email 正規化與唯一候選、`customer_id` 可信度、bundle 計次、與 `ShoplineOrder.valid_paid.dedup_content_drift`／`ProductNameResolver.orders_for` 的一致性。

## 9. 已知限制與正式站執行前必須確認

- **尚未取得正式站統計**：請先執行 group-buy-crm 端保管的唯讀檢查腳本（`docs/ops/production_readonly_checks.sql`，只含 SELECT／SHOW／EXPLAIN），重點看：同名多筆 `confirmed_alias` 的數量與分佈（9b）、`import_run_id` 為 NULL 的列（8）、`customer_id` 不一致／懸空（13）、正規化 Email 多位會員（14）、去重排除量與 canonical 折疊量（8、12）、View 的 `EXPLAIN`（18）。
- **`dedup_content_drift` 是既有規則的延用**：它目前只用在每日儀表板與商品月統計；用在會員層級是第一次，若它誤丟某客人的合法商品列，客服會看到不完整的購買史（開發 DB 排除 2,449 列，約 5.7%）。
- 現有 `customers#show` 頁面本身**沒有**套用去重與已付款過濾，所以 CRM 的次數可能比那個頁面少，這是預期的。
- 現有 scope 會靜默排除 `quantity`／`checkout_amount` 為 NULL 的列（開發 DB 1 列）；View 照抄，未在此修正。
- 「多筆 confirmed 一律 conflict」是字面規則；若正式站有大量「多筆但指向同一商品」的無害重複，會被標成商品對應異常，屆時再決定是否放寬。
- Render 的資料庫帳號是否有 `CREATEROLE`、資料庫區域與內部連線是否可行，需在正式站確認；role 用手動腳本建立。
- `schema_search_path` 只設在 development／test；任何其他會載入 `db/schema.rb` 的環境（例如 CI、staging 初始化）也要加，否則載入會失敗。
- 尚未做：`materialized view`、`security_invoker`（PG14 不支援）、對 `product_name_mappings` 加 partial unique index（本階段刻意不動，等正式站統計）。
