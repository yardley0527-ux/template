-- View 3: group_buy_crm.member_product_summaries
-- 一列 = (會員, 標準化商品或未歸類名稱)。購買次數 = COUNT(DISTINCT order_number)，同訂單被 primary/component 多路徑命中也只算一次。
-- mapping_status：mapped（已對應標準商品）/ unmapped（尚未對應）/ conflict（同名有多筆 confirmed_alias，商品對應異常，不歸入任何商品）。
WITH lines AS (               -- 只掃 View 2 一次（被引用多次時 PostgreSQL 會物化）
  SELECT l.shopline_customer_id, l.order_number, l.order_date, l.raw_product_name,
         l.mapping_status, l.product_key, l.bundle_component_keys
  FROM group_buy_crm.member_order_lines l
  WHERE l.shopline_customer_id IS NOT NULL
),
hits AS (
  SELECT shopline_customer_id, order_number, order_date, product_key AS pkey, 'mapped'::text AS mstatus
  FROM lines WHERE mapping_status = 'mapped'                                              -- primary
  UNION ALL
  SELECT l.shopline_customer_id, l.order_number, l.order_date, k.pkey, 'mapped'::text
  FROM lines l CROSS JOIN LATERAL pg_catalog.unnest(l.bundle_component_keys) AS k(pkey)  -- bundle 成分（只有 mapped 才有）
  UNION ALL
  SELECT shopline_customer_id, order_number, order_date,
         'raw:' || COALESCE(raw_product_name, ''), mapping_status
  FROM lines WHERE mapping_status <> 'mapped'                                             -- 未歸類 / 對應異常：各自獨立，不併入任何商品
)
SELECT h.shopline_customer_id,
       h.pkey                                                   AS product_key,
       COALESCE(cp.label, pg_catalog.substr(h.pkey, 5))         AS product_label,
       h.mstatus                                                AS mapping_status,
       pg_catalog.count(DISTINCT h.order_number)::integer       AS order_count,
       pg_catalog.min(h.order_date)                             AS first_order_date,
       pg_catalog.max(h.order_date)                             AS last_order_date
FROM hits h
LEFT JOIN public.crm_products cp ON cp.key = h.pkey
GROUP BY h.shopline_customer_id, h.pkey, cp.label, h.mstatus
