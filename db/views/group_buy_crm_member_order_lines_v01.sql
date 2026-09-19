-- View 2: group_buy_crm.member_order_lines  （Scenic: db/views/group_buy_crm_member_order_lines_v01.sql，只放 SELECT）
-- 一列 = 一筆「canonical 訂單商品」= (order_number, 原始商品名) 唯一。
-- 基準：ShoplineOrder.valid_paid + dedup_content_drift（語意等價），再加 canonical 化，處理重複匯入殘留。
-- 不含金額、Email、電話、地址。Email 正規化規則須與 members View、group-buy-crm EmailNormalizer 完全一致：
--   去除首尾空白（含全形 U+3000）、移除零寬字元（U+200B-200D, U+2060, U+FEFF）、轉小寫；不動 Gmail 的點與加號、不動網域。
-- trim 字元集用 chr() 組成（空白、TAB、LF、CR、U+3000），不可寫成含原始控制字元的字面值：
--   Scenic 會把 View 定義原樣寫進 db/schema.rb，Ruby 讀入 heredoc 時會吞掉字面的 CR，導致 schema:load 與 migrate 建出不同的 View。
-- 效能注意：不要把 window 改回 GROUP BY + self-join，也不要把「唯一候選」改回 JOIN unique_email：
--   window 過濾後 planner 會把列數估成 1~2，選巢狀迴圈，實測 20~55 秒；現在的寫法 < 1 秒。
WITH
norm_members AS (
  SELECT c.id,
         pg_catalog.lower(pg_catalog.btrim(
           pg_catalog.regexp_replace(c.email, E'[\\u200B-\\u200D\\u2060\\uFEFF]', '', 'g'),
           (' ' || pg_catalog.chr(9) || pg_catalog.chr(10) || pg_catalog.chr(13) || pg_catalog.chr(12288)))) AS ne
  FROM public.shopline_customers c
  WHERE NULLIF(pg_catalog.btrim(c.email), '') IS NOT NULL
),
src AS (                      -- valid_paid + dedup_content_drift
  -- 同 (訂單,數量,金額) 群組的 drift 判斷用 window 表達：distinct_names = 1 <=> min(product_name) = max(product_name)
  -- quantity / checkout_amount 為 NULL 的列：現有 scope 是 INNER JOIN ... =，NULL 不相等而被排除，這裡同樣排除。
  SELECT b.id, b.order_number, b.order_date, b.product_name, b.quantity, b.import_run_id, b.shopline_customer_id, b.ne
  FROM (
    SELECT o.id, o.order_number, o.order_date, o.product_name, o.quantity, o.import_run_id, o.shopline_customer_id,
           o.payment_status, o.email,
           pg_catalog.lower(pg_catalog.btrim(
             pg_catalog.regexp_replace(o.email, E'[\\u200B-\\u200D\\u2060\\uFEFF]', '', 'g'),
             (' ' || pg_catalog.chr(9) || pg_catalog.chr(10) || pg_catalog.chr(13) || pg_catalog.chr(12288)))) AS ne,
           pg_catalog.min(o.product_name) OVER w AS min_name,
           pg_catalog.max(o.product_name) OVER w AS max_name,
           pg_catalog.max(o.import_run_id) OVER w AS max_run
    FROM public.shopline_orders o
    WHERE o.quantity IS NOT NULL AND o.checkout_amount IS NOT NULL AND o.order_number IS NOT NULL
    WINDOW w AS (PARTITION BY o.order_number, o.quantity, o.checkout_amount)
  ) b
  WHERE (b.min_name = b.max_name OR b.import_run_id = b.max_run)
    AND b.payment_status = '已付款'
    AND NULLIF(b.order_number, '') IS NOT NULL
    AND NULLIF(b.email, '') IS NOT NULL
    AND b.order_date IS NOT NULL
),
latest AS (                   -- canonical 步驟 1：同 (訂單, 商品名) 只留「最新匯入批次」那批列（同批內的重複品項照留）
  SELECT s.*,
         pg_catalog.dense_rank() OVER (
           PARTITION BY s.order_number, s.product_name
           ORDER BY COALESCE(s.import_run_id, -1) DESC) AS run_rank
  FROM src s
),
canon AS (                    -- canonical 步驟 2：折成一列，訂購份數 = 該批列的 quantity 加總
  SELECT l.order_number, l.product_name,
         pg_catalog.max(l.order_date)                       AS order_date,
         pg_catalog.sum(l.quantity)::integer                AS line_quantity,
         pg_catalog.count(*)::integer                       AS source_line_count,
         pg_catalog.count(DISTINCT l.shopline_customer_id)  AS n_customer_ids,
         pg_catalog.min(l.shopline_customer_id)             AS customer_id,
         pg_catalog.count(DISTINCT l.ne)                    AS n_emails,
         pg_catalog.min(l.ne)                               AS ne
  FROM latest l
  WHERE l.run_rank = 1
  GROUP BY l.order_number, l.product_name
),
pool AS (                     -- 唯一候選（純 window，無 join）：訂單列與會員疊在一起，依正規化 Email 分組計算會員數
  SELECT false AS is_member, c.order_number, c.product_name, c.order_date, c.line_quantity, c.source_line_count,
         c.n_customer_ids, c.customer_id, c.n_emails, c.ne, NULL::bigint AS member_id
  FROM canon c
  UNION ALL
  SELECT true, NULL::varchar, NULL::varchar, NULL::timestamp, NULL::integer, NULL::integer,
         NULL::bigint, NULL::bigint, NULL::bigint, m.ne, m.id
  FROM norm_members m
  WHERE m.ne <> ''
),
resolved AS (
  SELECT p.*,
         pg_catalog.count(*) FILTER (WHERE p.is_member) OVER (PARTITION BY p.ne) AS n_members,   -- 這個 Email 對到幾位會員
         pg_catalog.min(p.member_id)                    OVER (PARTITION BY p.ne) AS only_member_id
  FROM pool p
),
mapping AS (                  -- 與 ProductNameResolver / orders_for 相同的比對條件：raw_name 完全相等、confirmed_alias。
  -- 同一 raw_name 有多筆 confirmed_alias 時「不套用任何一筆」（現有 unique index 是 (raw_name, source)，並不禁止這種情況）。
  SELECT m.raw_name,
         pg_catalog.count(*)::integer                                             AS candidate_count,
         CASE WHEN pg_catalog.count(*) = 1 THEN pg_catalog.min(m.id) END          AS mapping_id,
         CASE WHEN pg_catalog.count(*) = 1 THEN pg_catalog.min(m.crm_product_id) END AS crm_product_id
  FROM public.product_name_mappings m
  WHERE m.mapping_status = 'confirmed_alias'
  GROUP BY m.raw_name
),
comp AS (                     -- bundle 成分（與 orders_for 第二條路徑同來源）
  SELECT pmc.product_name_mapping_id,
         pg_catalog.array_agg(DISTINCT cp.key ORDER BY cp.key) AS keys
  FROM public.product_mapping_components pmc
  JOIN public.crm_products cp ON cp.id = pmc.crm_product_id
  GROUP BY pmc.product_name_mapping_id
)
SELECT
  -- 無歧義的唯一 key：JSON 陣列文字是單射編碼（不同的 (訂單號, 商品名) 一定得到不同字串；含 | 、換行、引號、反斜線、Unicode 皆可），
  -- 且不經過 hash，所以連「hash 碰撞」也不存在。相同 (訂單號, 商品名) 永遠得到相同 key，與匯入批次無關。
  pg_catalog.jsonb_build_array(r.order_number, r.product_name)::text AS order_line_key,
  CASE WHEN r.n_customer_ids = 1 AND mem.id IS NOT NULL THEN mem.id                  -- 優先：訂單上有效的 shopline_customer_id
       WHEN r.n_customer_ids = 0 AND r.n_emails = 1 AND r.n_members = 1 THEN r.only_member_id   -- 其次：Email 唯一對到一位會員才補
  END                                                           AS shopline_customer_id,
  CASE WHEN r.n_customer_ids = 1 AND mem.id IS NOT NULL THEN 'order_customer_id'
       WHEN r.n_customer_ids = 0 AND r.n_emails = 1 AND r.n_members = 1 THEN 'unique_email'
  END                                                           AS customer_link_source,
  CASE WHEN r.n_customer_ids = 1 AND mem.id IS NOT NULL
       THEN COALESCE(pg_catalog.lower(pg_catalog.btrim(
              pg_catalog.regexp_replace(mem.email, E'[\\u200B-\\u200D\\u2060\\uFEFF]', '', 'g'),
              (' ' || pg_catalog.chr(9) || pg_catalog.chr(10) || pg_catalog.chr(13) || pg_catalog.chr(12288)))) = r.ne, false)   -- 訂單已有 customer_id 時，Email 是否與該會員一致（供畫面標示衝突）
       ELSE true
  END                                                           AS email_consistent,
  r.order_number,
  r.order_date,
  r.product_name                                                AS raw_product_name,
  CASE WHEN COALESCE(mp.candidate_count, 0) > 1 THEN 'conflict'
       WHEN mp.crm_product_id IS NOT NULL       THEN 'mapped'
       ELSE 'unmapped'
  END                                                           AS mapping_status,          -- mapped / unmapped / conflict
  COALESCE(mp.candidate_count, 0)                               AS mapping_candidate_count,
  cp.key                                                        AS product_key,             -- conflict / unmapped 時為 NULL
  cp.label                                                      AS product_label,           -- conflict / unmapped 時為 NULL
  comp.keys                                                     AS bundle_component_keys,   -- 只有 mapped 才有
  r.line_quantity,                                                                   -- 「訂購份數」，不是瓶數
  r.source_line_count
FROM resolved r
LEFT JOIN public.shopline_customers mem ON mem.id = r.customer_id AND r.n_customer_ids = 1
LEFT JOIN mapping mp                    ON mp.raw_name = r.product_name
LEFT JOIN public.crm_products cp        ON cp.id = mp.crm_product_id          -- conflict 時 crm_product_id 為 NULL
LEFT JOIN comp                          ON comp.product_name_mapping_id = mp.mapping_id
WHERE NOT r.is_member
