# ManyChat 資料收集方案（對齊 CRM 行銷機會第一版）

> 狀態：規劃＋CRM 接收端已實作（`POST /manychat/events`）。**ManyChat 後台的 Flow 都還沒改**，下面的步驟要在後台照著設定。
> 盤點時間：2026-10-29。標「✅ API 確認」的是實際呼叫 ManyChat API 看到的；標「⏳ 待確認」的是 API 看不到、需要在後台確認的。

---

## 1. 現有設定盤點

### 1-1 帳號、Flow、Growth Tool

| 項目 | 現況 | 依據 |
|---|---|---|
| 同步中的帳號 | 只有 chloechao0527（API 金鑰 3135261 開頭） | ✅ API 確認 |
| Flow 數 | 51 個，**沒有資料夾** | ✅ API 確認（getFlows） |
| Flow 命名 | 有一半是範本預設名：「Get more collabs from Story replies」×14、「Auto-reply to comment in DM」×6、「Auto-DM links from comments」×6、「Turn story replies into leads」×4；另有「b群 story2」×2、「PDRN story2 copy」 | ✅ API 確認 |
| 有業務意義的 Flow | PDRN post1～6 updated、PDRN story2、b群1、b群 story2/3、暖宮 comment、食譜、營養、保養、Say hi to new followers、CRM記錄、Sequence Message 1 | ✅ API 確認 |
| Growth Tool | 12 個：7 個貼文／Reel 留言觸發（「Post or Reel Comments #13 copy copy copy…」）、5 個限動回覆 | ✅ API 確認（getGrowthTools 只給名稱與類型） |
| Growth Tool 綁哪篇貼文、觸發關鍵字 | API 看不到 | ⏳ 待確認 |
| 哪些 Flow 有「寫試算表」「設定來源欄」動作 | API 看不到 Flow 內容 | ⏳ 待確認 |
| 哪些 Flow 仍在使用中 | API 看不到 | ⏳ 待確認 |

### 1-2 標籤與自訂欄位

| 名稱 | 類型 | 用途判斷 | 問題 |
|---|---|---|---|
| 興趣_保養、興趣_營養、興趣_食譜 | 標籤 | 客人選了主題（推測來自「保養／營養／食譜」Flow） | ⏳ 待確認是客人點按鈕選的，還是 Flow 進來就自動貼；兩者語意不同 |
| 需求_產品、需求_食譜 | 標籤 | 當次需求 | 一直累積不會移除，無法分辨是哪天的需求 |
| 1022群發 | 標籤 | 一次性群發名單 | 活動標籤留在客人身上，日後無法判斷意義 |
| 來源 | 自訂欄位（文字） | 最後一次觸發的 Flow 名稱 | **每次互動都被覆蓋**；值是 Flow 名稱（「PDRN post5 updated」），改名就斷 |
| 卡別、累積消費、訂單數、最近購買、最近購買日 | 自訂欄位 | CRM 寫回（`Manychat::CustomerFieldSync`） | 只對**已確認身分**的人寫；ManyChat 端的值永遠不回寫 CRM |

### 1-3 互動資料品質（CRM 實際資料）

- 互動紀錄 120 筆中 **88 筆來源空白**；有值的是 PDRN post1/2/4/5 updated、新追蹤、PDRN77、b群動態、b群1。
- 試算表從 10/27 19:45 起有些列沒有時間，那些互動只能靠 API 補「最後一次」。
- 來源值的格式不一致：有的是 Flow 名稱（PDRN post5 updated），有的是自訂短名（PDRN77、b群動態）。

### 1-4 哪些會被覆蓋、哪些沒留下紀錄

- 被覆蓋：「來源」欄（每次互動覆蓋）、ManyChat 的 last_interaction（只留最後一次）。
- 沒留下可分析紀錄：客人在 Flow 裡按了哪個按鈕、要了什麼資訊、有沒有要真人協助——目前只有部分變成標籤，沒有時間、沒有來源。
- 需要客人主動提供：會員身分（Email／手機）、行銷同意、明確需求。
- 可以自動記錄：從哪個入口進 Flow（入口事件）、Flow 走到哪個節點。

---

## 2. 來源與活動命名規則

**穩定 ID 與顯示名稱分開**：ID 建立後不改；名稱可以改。CRM 的「ManyChat 來源設定」頁（`/manychat_sources`）維護對應表。

| 欄位 | 格式 | 例子 | 誰填 | 說明 |
|---|---|---|---|---|
| source_id | `<帳號縮寫>-<渠道>-<主題>-<類型><序號>` 小寫英數與 - | `chloe-ig-pdrn-post1` | 人工在 CRM 建立 | 每個「內容入口」一個；Flow 的 External Request 帶這個值 |
| campaign_id | `<年>-<月>-<主題>` | `2026-11-pdrn-launch` | 人工 | 同一波活動的多個入口共用 |
| account | IG 帳號 | `chloechao0527` | 自動 | |
| channel | instagram / facebook | `instagram` | 人工 | |
| content_type | post / reel / story / live / dm / follow / ad / other | `post` | 人工 | |
| content_ref | 貼文網址或 media id | `https://www.instagram.com/p/xxx/` | 人工 | API 拿不到 Growth Tool 綁的貼文，只能人工填 |
| product_keys | CRM 產品 key | `pdrn` | 人工 | 「內容相關」，不是客人的需求 |
| topic、trigger_keyword | 文字 | `PDRN 起跑點`、`PDRN` | 人工 | |
| flow_ns、flow_version | ManyChat Flow 的 ns、自訂版本 | `content20261020…`、`v2` | 人工 | Flow 改版時版本 +1，舊資料仍可分辨 |
| raw_names | 互動紀錄裡出現過的舊來源字串 | `PDRN post1 updated` | 人工 | 讓既有資料對到新 ID；**沒設定的來源不靠名稱猜** |

**首次、最近、歷史分開存**

| 資料 | 存在哪 | 規則 |
|---|---|---|
| 首次已觀測來源 | `manychat_subscribers.first_observed_source/at` | 只會被**更早**的觀測取代；不叫「首次接觸」，因為 10/23 前的互動不知道 |
| 最近來源 | `manychat_subscribers.source`（ManyChat「來源」欄） | 每次同步更新 |
| 完整事件歷史 | `manychat_interactions`（入口）＋`manychat_events`（Flow 節點事件） | 一次互動一筆，不覆蓋 |

---

## 3. 最小必要事件追蹤

### 3-1 候選事件分類

| 事件 | 分類 | 說明 |
|---|---|---|
| 從哪個內容入口進入 | **B 要改 Flow**（目前部分靠試算表＋「來源」欄） | 入口第一步加 External Request `entry` |
| 選擇主題／商品 | **B 要改 Flow** | 按鈕後加 `topic_selected` |
| 明確要求產品資訊／優惠 | **B 要改 Flow** | `info_requested`、`offer_requested` |
| 需要購買協助 | **B 要改 Flow** | `purchase_help_requested` |
| 要求真人協助 | **B 要改 Flow** | `human_requested` |
| 提交會員綁定申請 | **B 要改 Flow** | `binding_requested`（**不傳 Email／手機**，見第 5 節） |
| 流程送出購物連結 | **B 要改 Flow** | `shop_link_sent`：只代表 Flow 走到這個節點，**不代表點擊** |
| 真的點擊購物連結 | **C 需要追蹤連結** | 連結加 UTM（`utm_source=manychat&utm_campaign=<campaign_id>&utm_content=<source_id>`），從 Shopline 訂單的 UTM 欄位看到「有點而且下單」的人；單純點擊沒下單看不到 |
| 客人已讀訊息 | **D 無法可靠取得** | API 沒有已讀資料；ManyChat 後台的開啟率只能在後台看 |
| Flow 發送數、開啟率、點擊率 | **D 無法可靠取得**（透過 API） | 只在 ManyChat 後台 Analytics |
| 訂閱者狀態、最後互動、標籤、自訂欄位 | **A API 已能取得** | 已在 `Manychat::InteractionBackfill` 同步（標籤從這版開始存） |
| 新追蹤 | **A API 已能取得**（visitor 狀態＋「來源」欄＝新追蹤） | 追蹤不等於可私訊、不等於同意行銷 |

語意提醒：「留言索取食譜」≠「有意購買保健品」；`topic_selected=recipe` 不會被當成產品需求。

### 3-2 事件格式（CRM 已實作）

`POST https://<CRM 網域>/manychat/events`
Header：`X-Manychat-Token: <MANYCHAT_WEBHOOK_TOKEN>`、`Content-Type: application/json`

```json
{
  "account": "chloechao0527",
  "subscriber_id": "{{Contact Id}}",
  "ig_username": "{{Instagram Username}}",
  "event_type": "info_requested",
  "event_id": "",
  "event_time": "",
  "source_key": "chloe-ig-pdrn-post1",
  "campaign_key": "2026-11-pdrn-launch",
  "flow_ns": "content20261020xxxx",
  "flow_version": "v2",
  "properties": { "product_key": "pdrn" }
}
```

- `{{Contact Id}}`、`{{Instagram Username}}`：在 External Request 的 Body 編輯器用「+ 變數」選單插入（實際顯示名稱⏳待確認）。
- **event_id／event_time 可以留空**：留空時 CRM 用收到時間（分鐘）算去重 id，同一分鐘內同一人同類型的重送只記一筆；如果 ManyChat 有可用的時間變數，填進 event_time 會更準（⏳待確認有沒有這種變數）。
- 回應：`{"ok":true,"duplicate":false,"event_id":"..."}`；格式錯誤回 422 與原因；token 錯回 401。
- 只收白名單事件與屬性；Email、電話、姓名等欄位就算送來也不會存。

| event_type | 觸發條件 | 必要屬性 | 可用屬性 |
|---|---|---|---|
| entry | 客人從某個入口進入 Flow 的第一步 | — | — |
| topic_selected | 客人點選興趣主題按鈕 | topic：skincare / nutrition / recipe / product / other | — |
| info_requested | 客人點「想看產品介紹」 | — | product_key |
| offer_requested | 客人點「想知道優惠」 | — | product_key |
| purchase_help_requested | 客人點「想買、需要協助」 | — | product_key |
| human_requested | 客人點「找真人」 | — | — |
| shop_link_sent | Flow 送出購物連結（不代表點擊） | — | product_key |
| binding_requested | 客人點「綁定會員」 | — | — |
| consent_given | 客人在 Flow 按「同意接收」 | channel：ig_dm / line / email / sms、purpose、text_version | — |
| consent_withdrawn | 客人取消同意 | channel | — |

**驗證、重試、順序、失敗**
- 驗證：共用 token；`account`、`subscriber_id` 格式檢查；`product_key` 必須是 CRM 產品。
- 重試／重複：同一 event_id（或同內容同一分鐘）只記一次。ManyChat External Request 失敗會不會自動重試⏳待確認；建議在 External Request 的失敗分支不做任何事（不影響客人流程）。
- 順序：以 `event_time`（沒有時用收到時間）排序，不依收到順序。
- 失敗監控：用「入口事件數 ÷ 試算表同一來源列數」看回傳成功率（第 12 節）。

### 3-3 ManyChat 後台設定步驟（每個要加事件的節點）

1. 打開 Flow → 在要記錄的節點後面加一個 **Action** → 選 **External Request**。
2. Request type：**POST**；URL：`https://<CRM 網域>/manychat/events`。
3. Headers：加 `X-Manychat-Token`，值向工程師拿（同 `/manychat/webhook` 的 token）；`Content-Type: application/json`。
4. Body：貼上 3-2 的 JSON，改 `event_type`、`source_key`、`campaign_key`、`flow_ns`、`flow_version`、`properties`；`subscriber_id`、`ig_username` 用變數選單插入。
5. 按 **Test the request** 看到 `"ok": true` 就完成（⏳待確認 Test 時會不會用測試聯絡人產生一筆事件；會的話在 CRM 可以看到 subscriber_id 是測試帳號的事件）。
6. Response mapping：不需要。
7. 發布 Flow。

---

## 4. 標籤與自訂欄位重整

| 類別 | 放哪裡 | 命名 | 更新／失效 | 歷史 |
|---|---|---|---|---|
| 1. 客人明確選擇的興趣 | ManyChat 標籤 | `興趣_<主題>`（保留現有：保養／營養／食譜） | 只在客人**按按鈕選擇**時加；180 天沒再選就由客人下次互動時重新詢問（第 6 節問題 1） | `topic_selected` 事件 |
| 2. 從互動推論的興趣 | **不放 ManyChat**，CRM 用來源對應計算 | — | 每次查詢依時間窗口計算，不變成永久標籤 | `manychat_interactions` |
| 3. 當次需求 | **不再用標籤**；改事件 | — | 事件自帶時間，自然過期（行銷頁只看 7／14／30 天） | `manychat_events` |
| 4. 長期偏好 | ManyChat 自訂欄位（之後再加，例如「偏好聯絡管道」） | `偏好_<項目>` | 客人自己改 | 以事件紀錄每次變更 |
| 5. CRM 會員事實 | ManyChat 自訂欄位（卡別、累積消費…） | 現有名稱 | **只由 CRM 寫入**；ManyChat 端的值不會回寫 CRM | CRM 本身 |
| 6. 事件歷史 | CRM | — | 不覆蓋 | `manychat_events` |

- 舊標籤 `需求_產品`、`需求_食譜`：改用事件後停止新增，舊的保留不刪（避免影響現有 Flow 條件）⏳待確認有沒有 Flow 用它們分流。
- 活動標籤（如 `1022群發`）：活動結束 30 天後在後台移除；名單在 CRM 活動草稿已有快照，不需要靠標籤保存。
- 健康相關回答**不變成標籤**。

---

## 5. 會員綁定

| 方法 | 客人步驟 | 開發 | 能解決 | 防止綁錯 | 失敗處理 |
|---|---|---|---|---|---|
| **A. 人工確認**（第一版已做） | 無 | 已完成（`/manychat_matches`） | IG 相同的候選、舊程式自動選的關聯 | 只能從候選確認；多人同 IG 不自動選；操作留紀錄 | 解除關聯，那位顧客列入排除 |
| B. 引導登入會員後綁定 | 點 Flow 裡的「查會員權益」連結 → 登入官網 → 官網頁面帶著一次性代碼回 CRM | 要做一次性代碼頁（CRM）＋官網登入後跳轉（⏳待確認 Shopline 能否自訂登入後頁面） | 有官網帳號的客人自助綁定，身分最可靠 | 代碼一次性、10 分鐘失效，綁定的是**登入中的帳號** | 代碼過期請客人重來；登入失敗不綁 |
| C. 驗證 Email／手機 | 輸入 Email → 收驗證碼 → 回 Flow 輸入 | 要寄驗證碼（Email 或簡訊服務）＋CRM 驗證 API | 沒有官網帳號但有訂單 Email 的客人 | **只有輸入正確驗證碼才算**；驗證碼寄到會員檔裡的 Email，不寄到客人填的別的信箱；不回傳任何會員資料到 Flow | 3 次錯誤鎖 1 小時；找不到會員只回「已收到」，不透露是否存在 |
| D. 客服在對話中確認 | 客人提供訂單編號 → 客服在 CRM 比對後按確認 | 現有人工確認頁加「依訂單編號搜尋顧客」 | 主動問訂單的客人 | 訂單編號＋收件人姓名都要對 | 對不上就不綁 |

**建議**：第一版只用 A；第二步做 D（成本低，客服本來就會問訂單）；B 需要先確認 Shopline 能否自訂登入後頁面。**不要做「輸入 Email 和會員相符就直接綁定」**。

提出綁定的時機（有合理用途時才問，不是每個入口都問）：
- 客人問「我是什麼卡」「點數多少」「訂單到哪了」→ 這時說明「綁定後可以直接查」。
- 客人在 Flow 點「想買、需要協助」→ 客服接手時順便確認。

---

## 6. 分析用按鈕問題（少量、可直接回答）

| # | 客人看到的文字 | 選項 | 寫入 | CRM 能做的分析 | 不可以推論 |
|---|---|---|---|---|---|
| 1 | 想多看哪一類內容？ | 保養／營養／食譜／都看看 | `topic_selected`（topic）＋標籤 `興趣_<主題>` | 各來源帶來的興趣分布；內容方向建議 | 不代表有購買需求；「營養」不代表有健康問題 |
| 2 | 這次想知道什麼？ | 產品介紹／優惠活動／怎麼吃比較好 | `info_requested` / `offer_requested` / `topic_selected=product` | 「明確表達需求」客群；哪些內容帶出優惠詢問 | 選「怎麼吃」不推論身體狀況 |
| 3 | 需要幫你處理購買嗎？ | 我要買／先看看／找真人 | `purchase_help_requested` / 無 / `human_requested` | 需要協助的人；客服接手量 | 「先看看」不代表拒絕，不排除在內容之外 |

- 問題 3 只在客人選了問題 2 的「產品介紹」或「優惠」之後出現，不是每個人都問。
- 不問年齡、體重、疾病、懷孕、用藥。客人在私訊自己提到的健康狀況，只由客服處理，不寫進事件或標籤。

---

## 7. 聯絡資格與同意

| 資料 | 意義 | 來源 | CRM 顯示 |
|---|---|---|---|
| 平台聯絡資格 | 平台允許商家傳訊 | IG：客人傳訊後才開啟窗口（Meta 文件：多數情況 24 小時）；留言私訊每則留言 1 則、7 天內 | 一律「待確認」，發送前在 ManyChat 確認 |
| 訊息窗口狀態 | 現在能不能傳 | 系統沒有可靠資料；`last_interaction`、`ig_last_seen` 不能代表窗口開啟 | 待確認 |
| 各渠道行銷同意 | 客人同意收某渠道的行銷 | 目前沒有：Shopline 顧客匯入沒有帶同意欄位（全部是預設值，**狀態未知**） | 未知 |
| 退訂／拒絕 | 不再聯絡 | ManyChat「Unsubscribe from Instagram」Flow（⏳待確認觸發後是否改訂閱狀態）；`consent_withdrawn` 事件 | 之後接上後在客群排除 |

- 追蹤帳號、索取內容、留下 Email **都不等於**同意行銷。
- 若要收集同意：Flow 裡顯示固定文字（例：「我同意苼莛國際透過 LINE 傳送新品與優惠通知，可隨時取消」），按鈕「同意」→ `consent_given`（channel=line、purpose=新品與優惠通知、text_version=v1）。文字改了就換 text_version。

---

## 8. 調整清單

| 優先 | ManyChat 調整 | 為什麼 | 修改哪裡 | 新增 | CRM 怎麼用 | 人工／開發 | 驗收 | 維護成本 |
|---|---|---|---|---|---|---|---|---|
| P1 | 所有寫試算表的 Flow 都補上 time | 10/27 起有列沒時間，只能靠 API 補最後一次 | 每個有「Google Sheets Insert Row」的 Flow | — | 互動有正確時間 | 人工（後台） | 同步紀錄 `rows_without_time` 變 0 | 低 |
| P1 | 在 CRM 建來源設定，把現有來源字串對到 source_id 與產品 | 來源名稱不穩定、要人工對應產品 | CRM `/manychat_sources` | source_id、product_keys | 產品互動機會、來源表現 | 人工（CRM） | 行銷機會頁「近 30 天來源已設定」= 全部 | 低：新入口時建一筆 |
| P1 | 試點 Flow 入口加 `entry` 事件 | 不再依賴會被覆蓋的「來源」欄 | PDRN post Flow（見第 9 節） | External Request | 互動紀錄 event_type=flow_event、來源可信 | 人工（後台） | 試點來源的 flow_event 數 ≈ 試算表列數 | 中：每個新入口要加 |
| P1 | 試點 Flow 加問題 2、3 與對應事件 | 分開「看過內容」與「明確需求」 | 同上 | `info_requested` 等 | 明確表達需求客群、AI 建議 | 人工（後台） | 行銷頁「明確表達需求」出現數字 | 中 |
| P2 | 整理 Growth Tool 與 Flow 名稱 | 範本預設名無法辨識 | 後台改名、刪除不用的 copy | — | 人工對照更容易 | 人工 | 名稱與 source_id 一一對應 | 低 |
| P2 | 興趣主題 Flow（保養／營養／食譜）改成按鈕選擇＋`topic_selected` | 分開「客人選的」與「系統推論」 | 食譜、營養、保養 Flow | 事件 | 興趣分布、內容建議 | 人工 | 事件與標籤數一致 | 低 |
| P2 | 綁定流程 D（訂單編號人工確認） | 提高已確認身分比例 | 客服流程＋CRM 搜尋 | — | 轉換分析可用人數增加 | 開發（小） | 已確認比例每週上升 | 低 |
| P3 | 同意收集（LINE／Email） | 目前沒有任何可靠同意資料 | 新 Flow 節點 | `consent_given/withdrawn` | 之後的發送資格 | 人工＋法務確認文字 | 事件有 text_version | 中 |
| P3 | 綁定流程 B 或 C | 自助綁定 | 新開發 | — | — | 開發（中） | — | 中 |

---

## 9. 建議先改的試點 Flow

1. **PDRN post1～6 updated**：目前唯一有穩定來源值、互動量最多的一組（來源欄有值的互動大多來自這裡），而且對應單一產品（PDRN），改完馬上能比較「內容互動 → 明確需求 → 下單」。
2. **Say hi to new followers**：新追蹤在訂閱者裡佔很大比例（10/29 時 140 人中約 50 人），但幾乎都是沒互動的 visitor。加問題 1（想看哪類內容）能讓一部分人留下明確興趣；客人按了按鈕之後才可能開啟訊息窗口（以 ManyChat 顯示為準）。

---

## 10. 完整範例：IG 內容入口 → 需求互動 → CRM 記錄 → AI 建議

1. 客人在 PDRN 第 1 篇貼文留言「PDRN」→ Growth Tool 觸發「PDRN post1 updated」Flow。
2. Flow 第一步 External Request：`entry`，source_key=`chloe-ig-pdrn-post1`。
   → CRM：`manychat_events` 一筆、`manychat_interactions` 一筆（event_type=flow_event、來源可信）。
3. Flow 私訊介紹內容後問「這次想知道什麼？」→ 客人按「優惠活動」→ `offer_requested`（product_key=pdrn）。
   → CRM：行銷機會「產品互動機會」的 PDRN「明確表達需求」+1。
4. 問「需要幫你處理購買嗎？」→ 客人按「我要買」→ `purchase_help_requested`，Flow 轉真人。
5. 客服在對話中請客人提供訂單編號（若是舊客）→ 在 CRM 身分比對頁確認 → 變成已確認身分。
6. 隔週按「產生 AI 建議」：快照裡有「明確表達 PDRN 需求」客群人數、PDRN 貼文來源的互動與（樣本夠時）下單率 → AI 提出「PDRN 優惠詢問者跟進」建議卡，引用該客群與指標；沒有有效優惠就寫「沒有可引用的有效優惠」。
7. 按「用這張卡建立活動草稿」→ 名單快照保存；實際私訊前在 ManyChat 確認每個人的窗口。

---

## 11. 不改 ManyChat 也能先做的

- 身分比對人工確認（`/manychat_matches`）
- 來源設定與產品對應（`/manychat_sources`），讓既有互動有產品關聯
- 近期互動者、互動後未下單、從未購買（已確認身分）
- 回購機會（完全依 CRM 回購週期，不受 ManyChat 影響）
- 來源表現（有分母、觀察期、樣本限制）
- AI 建議（以上述資料為依據）＋活動草稿

## 12. 必須改 ManyChat 後才成立的

- 「明確表達產品需求」客群（需要 info／offer／purchase_help 事件）
- 客人選擇的興趣 vs 系統推論的興趣
- 可信的完整入口歷史（不再依賴被覆蓋的「來源」欄與 API 只給的最後一次）
- 需要真人協助的人數與轉換
- 行銷同意與退訂

## 13. 資料改善追蹤

| 指標 | 算法 | 在哪看 | 目標 |
|---|---|---|---|
| 來源完整率 | 近 30 天互動中，來源已在來源設定裡的比例 | 行銷機會頁資料狀態列「近 30 天來源已設定」 | 100% |
| 時間完整率 | 最近一次同步沒有時間的試算表列數 | 資料缺口說明（`rows_without_time`） | 0 |
| 來源可信率 | 互動中 event_type 是 sheet_row 或 flow_event（不是 API 補入）的比例 | 資料狀態列「互動紀錄類型」；來源表現「來源可信度」欄 | ↑ |
| 事件回傳成功率 | 試點來源的 flow_event 數 ÷ 同來源試算表列數 | 來源表現頁對照兩種紀錄 | ≥ 95% |
| 已確認身分覆蓋率 | verified ÷ 全部訂閱者 | 資料狀態列 | 每週上升 |
| 候選待確認數 | candidate 人數 | 資料狀態列、身分比對頁 | ↓ |

---

## 需要你從 ManyChat 後台提供的（只列真正影響設計的）

1. **任一個 PDRN post Flow 的完整截圖**（含 Google Sheets 動作與「來源」欄設定），確認時間與來源是怎麼寫的。
2. **External Request 的變數選單截圖**：確認 Contact Id、Instagram Username 的實際名稱，以及有沒有「目前時間」變數。
3. **「保養／營養／食譜」Flow 截圖**：確認興趣標籤是客人按按鈕才加，還是進來就自動加。
4. **12 個 Growth Tool 各自綁哪篇貼文、關鍵字**（列表畫面即可），用來填來源設定的 content_ref 與 trigger_keyword。
