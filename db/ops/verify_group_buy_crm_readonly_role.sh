#!/usr/bin/env bash
# 以 group_buy_crm_ro「真實登入」驗證權限（role 層級的設定只在登入時生效，SET ROLE 不算）。
#
# 用法（連線字串放環境變數，避免出現在 ps / shell history；本腳本不會輸出它）：
#   本機:   GROUP_BUY_CRM_RO_URL="dbname=smartadmin_rails_full_development user=group_buy_crm_ro" \
#             db/ops/verify_group_buy_crm_readonly_role.sh
#   正式站: read -s "GROUP_BUY_CRM_RO_URL?貼上唯讀 role 的連線字串: "; export GROUP_BUY_CRM_RO_URL
#             db/ops/verify_group_buy_crm_readonly_role.sh ; unset GROUP_BUY_CRM_RO_URL
#
# 安全性：所有「預期會失敗的寫入」都包在 BEGIN TRANSACTION READ WRITE ... ROLLBACK 裡。
#   - 用 READ WRITE 是為了直接測到「權限層」，不被 role 預設的 read-only 遮住；
#   - 就算權限真的漏了、語句成功，ROLLBACK 也會還原，不會留下任何資料表或資料。
# 結束碼：有任何 FAIL 就回傳 1。WARN 代表「可選硬化」尚未套用（見 db/ops/group_buy_crm_readonly_role.sql 最後一段）。
set -u

URL="${1:-${GROUP_BUY_CRM_RO_URL:-}}"
if [[ -z "$URL" ]]; then
  echo "請以第一個參數或環境變數 GROUP_BUY_CRM_RO_URL 提供唯讀 role 的連線字串" >&2
  exit 2
fi

PASS=0; FAIL=0; WARN=0
run() { psql "$URL" -X -q -A -t -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n        %s\n' "$1" "${2:-}"; }
warn() { WARN=$((WARN+1)); printf 'WARN  %s\n' "$1"; }

# 預期成功並且輸出等於 expected
expect_value() { # name sql expected
  local out rc; out="$(run "$2")"; rc=$?
  if [[ $rc -eq 0 && "$out" == "$3" ]]; then ok "$1"; else bad "$1" "預期 [$3]，實際 [rc=$rc] $(echo "$out" | head -2 | tr '\n' ' ')"; fi
}
# 預期成功（不檢查內容）
expect_ok() { # name sql
  local out rc; out="$(run "$2")"; rc=$?
  if [[ $rc -eq 0 ]]; then ok "$1"; else bad "$1" "$(echo "$out" | head -2 | tr '\n' ' ')"; fi
}
# 預期失敗且訊息符合 pattern（在 READ WRITE 交易內執行，一律 ROLLBACK）
expect_denied() { # name sql pattern
  local out rc; out="$(run "BEGIN TRANSACTION READ WRITE; $2; ROLLBACK;")"; rc=$?
  if [[ $rc -ne 0 && "$out" =~ $3 ]]; then ok "$1"
  elif [[ $rc -eq 0 ]]; then bad "$1" "不該成功卻成功了（已 ROLLBACK）"
  else bad "$1" "失敗了，但原因不是預期的：$(echo "$out" | head -2 | tr '\n' ' ')"; fi
}
# 可選硬化：成功 = WARN，失敗 = PASS
expect_denied_or_warn() { # name sql pattern
  local out rc; out="$(run "BEGIN TRANSACTION READ WRITE; $2; ROLLBACK;")"; rc=$?
  if [[ $rc -ne 0 && "$out" =~ $3 ]]; then ok "$1"; elif [[ $rc -eq 0 ]]; then warn "$1（可選硬化尚未套用；已 ROLLBACK）"; else bad "$1" "$(echo "$out" | head -2 | tr '\n' ' ')"; fi
}

echo "== 0. 連線與 session 設定 =="
expect_value "登入身分是 group_buy_crm_ro"                  "SELECT current_user" "group_buy_crm_ro"
expect_value "不是 superuser / 無 createrole / createdb / replication / bypassrls" \
  "SELECT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)::text FROM pg_roles WHERE rolname = current_user" "false"
expect_value "search_path = group_buy_crm, pg_catalog（不含 public）" "SHOW search_path" "group_buy_crm, pg_catalog"
expect_value "default_transaction_read_only = on"           "SHOW default_transaction_read_only" "on"
expect_value "statement_timeout = 15s"                      "SHOW statement_timeout" "15s"

echo "== 1. 三個 View 可讀，欄位與契約完全一致 =="
for v in members member_order_lines member_product_summaries; do
  expect_ok "SELECT 1 FROM group_buy_crm.$v LIMIT 1" "SELECT 1 FROM group_buy_crm.$v LIMIT 1"
done
cols() { echo "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='group_buy_crm' AND table_name='$1'"; }
expect_value "members 欄位" "$(cols members)" \
  "shopline_customer_id,shopline_id,name,email,normalized_email,membership_level,total_amount,blacklisted,membership_expiry_date,joined_at,credits,points,last_order_date"
expect_value "member_order_lines 欄位" "$(cols member_order_lines)" \
  "order_line_key,shopline_customer_id,customer_link_source,email_consistent,order_number,order_date,raw_product_name,mapping_status,mapping_candidate_count,product_key,product_label,bundle_component_keys,line_quantity,source_line_count"
expect_value "member_product_summaries 欄位" "$(cols member_product_summaries)" \
  "shopline_customer_id,product_key,product_label,mapping_status,order_count,first_order_date,last_order_date"

echo "== 2. 權限清單：整個資料庫中，這個 role 只擁有三個 View 的 SELECT =="
expect_value "public schema 內任何表/View 都沒有任何權限" \
  "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f') AND (has_table_privilege(current_user,c.oid,'SELECT') OR has_table_privilege(current_user,c.oid,'INSERT') OR has_table_privilege(current_user,c.oid,'UPDATE') OR has_table_privilege(current_user,c.oid,'DELETE') OR has_table_privilege(current_user,c.oid,'TRUNCATE') OR has_table_privilege(current_user,c.oid,'REFERENCES') OR has_table_privilege(current_user,c.oid,'TRIGGER'))" "0"
expect_value "group_buy_crm 內恰好 3 個 View 有 SELECT，且沒有其他權限" \
  "SELECT count(*) FILTER (WHERE has_table_privilege(current_user,c.oid,'SELECT'))::text || '/' || count(*) FILTER (WHERE has_table_privilege(current_user,c.oid,'INSERT') OR has_table_privilege(current_user,c.oid,'UPDATE') OR has_table_privilege(current_user,c.oid,'DELETE') OR has_table_privilege(current_user,c.oid,'TRUNCATE') OR has_table_privilege(current_user,c.oid,'REFERENCES') OR has_table_privilege(current_user,c.oid,'TRIGGER'))::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='group_buy_crm' AND c.relkind IN ('r','p','v','m','f')" "3/0"
expect_value "group_buy_crm schema：有 USAGE、沒有 CREATE" \
  "SELECT has_schema_privilege(current_user,'group_buy_crm','USAGE')::text || '/' || has_schema_privilege(current_user,'group_buy_crm','CREATE')::text" "true/false"
expect_value "View 為擁有者權限（沒有 security_invoker 等 reloptions）" \
  "SELECT coalesce(string_agg(coalesce(reloptions::text,''), ''), '') FROM pg_class WHERE oid IN ('group_buy_crm.members'::regclass,'group_buy_crm.member_order_lines'::regclass,'group_buy_crm.member_product_summaries'::regclass)" ""

echo "== 3. 原始資料表直接讀取必須失敗 =="
for t in shopline_customers shopline_orders customer_profiles product_name_mappings product_mapping_components crm_products users; do
  expect_denied "SELECT public.$t" "SELECT count(*) FROM public.$t" "permission denied for table $t"
done
expect_denied "不寫 schema 名稱也解析不到原始表（search_path 不含 public）" "SELECT count(*) FROM shopline_customers" 'relation "shopline_customers" does not exist'

echo "== 4. 寫入必須失敗（READ WRITE 交易內，測權限層；一律 ROLLBACK）=="
expect_denied "INSERT 原始表"      "INSERT INTO public.shopline_customers(email) VALUES ('probe@example.invalid')" "permission denied for table shopline_customers"
expect_denied "UPDATE 原始表"      "UPDATE public.shopline_customers SET email = email" "permission denied for table shopline_customers"
expect_denied "DELETE 原始表"      "DELETE FROM public.shopline_orders" "permission denied for table shopline_orders"
expect_denied "TRUNCATE 原始表"    "TRUNCATE public.shopline_orders" "permission denied for table shopline_orders"
# 這些 View 含 JOIN / WITH，本來就不可更新：PostgreSQL 會先報 "cannot insert into view"，而不是 "permission denied"。
# 兩種訊息都代表「寫不進去」；權限層本身另由第 2 節（沒有 INSERT/UPDATE/DELETE 權限）驗證。
expect_denied "對 View INSERT"     "INSERT INTO group_buy_crm.members(shopline_customer_id) VALUES (1)" "permission denied for (table|view) members|cannot insert into view \"members\""
expect_denied "對 View UPDATE"     "UPDATE group_buy_crm.members SET name = 'x'" "permission denied for (table|view) members|cannot update view \"members\""
expect_denied "對 View DELETE"     "DELETE FROM group_buy_crm.member_order_lines" "permission denied for (table|view) member_order_lines|cannot delete from view \"member_order_lines\""

echo "== 5. CREATE / 提權 =="
expect_denied "CREATE TABLE 於 group_buy_crm" "CREATE TABLE group_buy_crm.gbcrm_probe(i int)" "permission denied for schema group_buy_crm"
expect_denied "CREATE VIEW 於 group_buy_crm"  "CREATE VIEW group_buy_crm.gbcrm_probe_v AS SELECT 1" "permission denied for schema group_buy_crm"
expect_denied "CREATE SCHEMA"                 "CREATE SCHEMA gbcrm_probe_schema" "permission denied for database"
OWNER="$(run "SELECT viewowner FROM pg_views WHERE schemaname='group_buy_crm' AND viewname='members'")"
expect_denied "SET ROLE 成 View 擁有者（提權）" "SET ROLE \"$OWNER\"" "permission denied to set role"
expect_denied_or_warn "CREATE TABLE 於 public（role 自行關閉 read-only 後）" "CREATE TABLE public.gbcrm_probe(i int)" "permission denied for schema public"
expect_denied_or_warn "CREATE TEMP TABLE"                                  "CREATE TEMP TABLE gbcrm_probe_tmp(i int)" "permission denied to create temporary tables"

echo
echo "結果：PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
[[ $FAIL -eq 0 ]] || exit 1
