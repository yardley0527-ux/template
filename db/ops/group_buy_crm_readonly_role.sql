-- 手動執行（不放 migration）：以 smartadmin 資料庫「擁有者」身分，在 migration 建好 View 之後執行。
-- 密碼不寫在這裡：建立後在 psql 用  \password group_buy_crm_ro  互動輸入
--   （psql 在 client 端先加密再送出，不會出現在 server log、shell history、repo 或 migration）。
CREATE ROLE group_buy_crm_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5;

ALTER ROLE group_buy_crm_ro SET default_transaction_read_only = on;               -- 軟保險（role 自己可改掉，不是硬保證）
ALTER ROLE group_buy_crm_ro SET statement_timeout = '15s';
ALTER ROLE group_buy_crm_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE group_buy_crm_ro SET search_path = group_buy_crm, pg_catalog;          -- 不含 public，原始資料表名稱根本解析不到

GRANT USAGE  ON SCHEMA group_buy_crm TO group_buy_crm_ro;
GRANT SELECT ON group_buy_crm.members,
                group_buy_crm.member_order_lines,
                group_buy_crm.member_product_summaries TO group_buy_crm_ro;

-- 不要對 shopline_customers / shopline_orders / customer_profiles 等原始表授權任何權限。
-- View 以擁有者權限執行（不加 security_invoker），所以這個 role 不需要、也不應該有原始表權限。

-- ---- 可選硬化（預設不執行，需另行確認影響）----
-- PostgreSQL 14 以前，public schema 預設讓 PUBLIC 可以建表；上面的 default_transaction_read_only 只是軟保險。
-- 若要讓「CREATE 一定失敗」成為硬保證：
--   REVOKE CREATE ON SCHEMA public FROM PUBLIC;          -- 只影響非擁有者的 role；應用程式以擁有者連線，不受影響
--   REVOKE TEMPORARY ON DATABASE <db_name> FROM PUBLIC;   -- 連暫存表都禁止
