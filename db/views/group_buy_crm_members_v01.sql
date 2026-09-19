-- View 1: group_buy_crm.members
SELECT c.id                                   AS shopline_customer_id,
       c.shopline_id,
       c.full_name                            AS name,
       c.email,
       NULLIF(pg_catalog.lower(pg_catalog.btrim(
         pg_catalog.regexp_replace(c.email, E'[\\u200B-\\u200D\\u2060\\uFEFF]', '', 'g'),
         (' ' || pg_catalog.chr(9) || pg_catalog.chr(10) || pg_catalog.chr(13) || pg_catalog.chr(12288)))), '')              AS normalized_email,
       c.membership_level,
       c.total_amount,                                                            -- 唯一累積消費來源，NULL 就是 NULL
       (COALESCE(c.blacklisted, false)
        OR EXISTS (SELECT 1 FROM public.customer_profiles p
                   WHERE p.shopline_customer_id = c.id AND COALESCE(p.blacklisted, false))) AS blacklisted,
       c.membership_expiry_date,
       c.joined_at,
       c.current_shopping_credits             AS credits,
       c.current_points                       AS points,
       lo.last_order_date
FROM public.shopline_customers c
LEFT JOIN (SELECT l.shopline_customer_id, pg_catalog.max(l.order_date) AS last_order_date
           FROM group_buy_crm.member_order_lines l
           WHERE l.shopline_customer_id IS NOT NULL
           GROUP BY l.shopline_customer_id) lo ON lo.shopline_customer_id = c.id
