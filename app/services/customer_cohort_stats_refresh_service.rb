# frozen_string_literal: true

# 首購產品分析的結果表（customer_cohort_stats）整批重算。
#
# 全部在資料庫裡用一條 SQL 算完再寫入，web 程序不載入訂單明細
# （2026-11-16 在 Ruby 裡載入 4.7 萬列訂單讓正式站記憶體不足重啟，首購產品分析第一版的教訓）。
#
# 同一個人：跟 customer_purchase_summaries／客人資料庫的「首購來源」一致，用 手機 > email 合併。
# 首購來源：第一筆已付款訂單裡，依 CustomerPurchaseSummaryRefreshService::SERIES_OPTIONS 優先順序挑產品，
#           PDRN 再看品名有沒有「預購」拆成 PDRN 預購／PDRN 現貨，都對不到算「其他」。
# 回購：首購那天之後「另一天」的任何已付款訂單。
# 黑名單（含同 IG 的其他 email）標記後不寫入。
class CustomerCohortStatsRefreshService
  SERIES = CustomerPurchaseSummaryRefreshService::SERIES_OPTIONS
  SERIES_KEYWORDS = CustomerPurchaseSummaryRefreshService::SERIES_KEYWORDS
  OTHER = "其他"
  LEVEL_RANK = { "一般會員" => 0, "白卡" => 1, "銀卡" => 2, "金卡" => 3, "黑卡" => 4 }.freeze

  # 跨買用的產品類別，依序比對（瘦身組合要在肉鹼／代謝錠前面）
  FAMILY_PATTERNS = [
    ["瘦身組合", "肉鹼1代謝錠1%"],
    ["PDRN", "%PDRN%"], ["全能", "%全能%"], ["代謝錠", "%代謝錠%"], ["肉鹼", "%肉鹼%"], ["薑黃", "%薑黃%"],
    ["清纖粉", "%清纖粉%"], ["穀胱甘肽", "%穀胱甘肽%"], ["益生菌", "%益生菌%"], ["魚油", "%魚油%"],
    ["蝦紅素", "%蝦紅素%"], ["維DK鈣", "%維D%"], ["膠原蛋白", "%膠原%"], ["冰晶蕃茄", "%冰晶%"],
    ["私密粉", "%私密粉%"], ["美白", "%美白%"]
  ].freeze

  def self.call
    new.call
  end

  def self.sources
    SERIES.flat_map { |s| s == "PDRN" ? ["PDRN 預購", "PDRN 現貨"] : [s] } + [OTHER]
  end

  def call
    conn = ActiveRecord::Base.connection
    count = nil
    ActiveRecord::Base.transaction do
      conn.execute("SET LOCAL statement_timeout = '600s'")
      conn.execute("DELETE FROM customer_cohort_stats")
      count = conn.exec_update(insert_sql)
    end
    Rails.cache.delete("customer_cohort_stats/refreshed_at")
    count
  end

  def insert_sql
    bl_emails = MessageListBuilder.blacklisted_emails.keys
    bl_igs = MessageListBuilder.blacklisted_igs.to_a
    q = ->(v) { ActiveRecord::Base.connection.quote(v) }
    arr = ->(list) { list.empty? ? "ARRAY[]::text[]" : "ARRAY[#{list.map { |v| q.(v) }.join(',')}]::text[]" }

    series_values = SERIES.each_with_index.flat_map do |s, i|
      (SERIES_KEYWORDS[s] || [s]).map { |kw| "(#{q.(s)}, #{i + 1}, #{q.("%#{kw}%")})" }
    end.join(", ")
    family_case = "CASE " + FAMILY_PATTERNS.map { |name, pat| "WHEN l.pn LIKE #{q.(pat)} THEN #{q.(name)}" }.join(" ") + " ELSE #{q.(OTHER)} END"
    rank_case = ->(col) { "CASE #{col} " + LEVEL_RANK.map { |l, r| "WHEN #{q.(l)} THEN #{r}" }.join(" ") + " ELSE 0 END" }

    <<~SQL
      INSERT INTO customer_cohort_stats (
        identity_key, source, source_family, first_date, first_amount, first_items, level_at_first,
        after_days, after_amount, first_after_date, same_again, cross_families, cross_revenue,
        last_order_date, last_items, level_now, upgraded, customer_id, name, instagram_account, refreshed_at,
        second_families
      )
      WITH lines AS (
        SELECT so.order_number, so.order_date::date AS d, LOWER(TRIM(so.email)) AS em,
               NULLIF(LOWER(TRIM(so.instagram_account)), '') AS ig, NULLIF(so.membership_level, '') AS lvl,
               so.total_amount, COALESCE(so.product_name, '') AS pn,
               COALESCE(NULLIF(so.quantity, 0), 1) AS qty, COALESCE(so.checkout_amount, 0) AS price
        FROM shopline_orders so
        WHERE so.payment_status = '已付款' AND so.order_number IS NOT NULL AND TRIM(so.order_number) <> ''
          AND so.email IS NOT NULL AND TRIM(so.email) <> '' AND so.order_date IS NOT NULL
      ),
      phones AS (
        SELECT LOWER(TRIM(email)) AS em, MAX(NULLIF(TRIM(mobile_phone), '')) AS phone
        FROM shopline_customers WHERE email IS NOT NULL GROUP BY 1
      ),
      orders AS (
        SELECT l.order_number, MIN(l.d) AS d, COALESCE(MAX(p.phone), MIN(l.em)) AS ik,
               MAX(l.lvl) AS lvl, COALESCE(NULLIF(MAX(l.total_amount), 0), SUM(l.price * l.qty)) AS amt
        FROM lines l LEFT JOIN phones p ON p.em = l.em
        GROUP BY l.order_number
      ),
      ranked AS (
        SELECT o.*,
               ROW_NUMBER() OVER (PARTITION BY o.ik ORDER BY o.d, o.order_number) AS rn,
               ROW_NUMBER() OVER (PARTITION BY o.ik ORDER BY o.d DESC, o.order_number DESC) AS rn_desc
        FROM orders o
      ),
      blacklisted AS (
        SELECT DISTINCT r.ik FROM lines l JOIN ranked r ON r.order_number = l.order_number
        WHERE l.em = ANY(#{arr.(bl_emails)}) OR l.ig = ANY(#{arr.(bl_igs)})
      ),
      firsts AS (SELECT * FROM ranked WHERE rn = 1 AND ik NOT IN (SELECT ik FROM blacklisted)),
      lasts AS (SELECT * FROM ranked WHERE rn_desc = 1),
      fam_lines AS (
        SELECT r.ik, r.d, l.order_number, l.pn, l.price * l.qty AS rev, #{family_case} AS fam
        FROM lines l JOIN ranked r ON r.order_number = l.order_number
      ),
      series_values(series, prio, pat) AS (VALUES #{series_values}),
      first_series AS (
        SELECT f.ik, MIN(sv.prio) AS prio,
               BOOL_OR(l.pn LIKE '預購%' AND l.pn LIKE '%PDRN%') AS has_pre
        FROM firsts f JOIN lines l ON l.order_number = f.order_number
        LEFT JOIN series_values sv ON l.pn LIKE sv.pat
        GROUP BY f.ik
      ),
      first_items AS (
        SELECT f.ik, STRING_AGG(DISTINCT l.pn, '、') AS items
        FROM firsts f JOIN lines l ON l.order_number = f.order_number WHERE l.price > 0 GROUP BY f.ik
      ),
      last_items AS (
        SELECT la.ik, STRING_AGG(DISTINCT l.pn, '、') AS items
        FROM lasts la JOIN lines l ON l.order_number = la.order_number WHERE l.price > 0 GROUP BY la.ik
      ),
      src AS (
        SELECT fs.ik,
               CASE WHEN sv.series IS NULL THEN #{q.(OTHER)}
                    WHEN sv.series = 'PDRN' THEN CASE WHEN fs.has_pre THEN 'PDRN 預購' ELSE 'PDRN 現貨' END
                    ELSE sv.series END AS source,
               COALESCE(sv.series, #{q.(OTHER)}) AS source_family
        FROM first_series fs
        LEFT JOIN (SELECT DISTINCT series, prio FROM series_values) sv ON sv.prio = fs.prio
      ),
      after_orders AS (
        SELECT r.ik, COUNT(DISTINCT r.d) AS days, SUM(r.amt) AS amt, MIN(r.d) AS first_after
        FROM ranked r JOIN firsts f ON f.ik = r.ik WHERE r.d > f.d GROUP BY r.ik
      ),
      after_fams AS (
        SELECT fl.ik, fl.fam, SUM(fl.rev) AS rev
        FROM fam_lines fl JOIN firsts f ON f.ik = fl.ik
        WHERE fl.d > f.d AND fl.rev > 0 GROUP BY fl.ik, fl.fam
      ),
      after_cross AS (
        SELECT af.ik,
               BOOL_OR(af.fam = s.source_family) AS same_again,
               COALESCE(ARRAY_AGG(af.fam ORDER BY af.rev DESC) FILTER (WHERE af.fam NOT IN (s.source_family, #{q.(OTHER)})), ARRAY[]::varchar[]) AS cross_families,
               COALESCE(JSONB_OBJECT_AGG(af.fam, ROUND(af.rev)) FILTER (WHERE af.fam NOT IN (s.source_family, #{q.(OTHER)})), '{}'::jsonb) AS cross_revenue
        FROM after_fams af JOIN src s ON s.ik = af.ik GROUP BY af.ik
      ),
      second_fams AS (
        SELECT fl.ik, ARRAY_AGG(DISTINCT fl.fam) AS fams
        FROM fam_lines fl JOIN after_orders ao ON ao.ik = fl.ik AND fl.d = ao.first_after
        WHERE fl.rev > 0 AND fl.fam <> #{q.(OTHER)} GROUP BY fl.ik
      ),
      custs AS (
        SELECT COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(sc.email))) AS ik, sc.id, sc.full_name,
               sc.instagram_account, COALESCE(NULLIF(sc.membership_level, ''), '一般會員') AS lvl
        FROM shopline_customers sc WHERE sc.email IS NOT NULL
      ),
      cust_pick AS (
        SELECT DISTINCT ON (ik) ik, id, full_name, instagram_account, lvl
        FROM custs ORDER BY ik, #{rank_case.('lvl')} DESC, (full_name IS NULL OR full_name = '') ASC, id DESC
      )
      SELECT f.ik, s.source, s.source_family, f.d, ROUND(f.amt, 2), fi.items,
             COALESCE(f.lvl, '一般會員'),
             COALESCE(ao.days, 0), COALESCE(ROUND(ao.amt, 2), 0), ao.first_after,
             COALESCE(ac.same_again, FALSE), COALESCE(ac.cross_families, ARRAY[]::varchar[]), COALESCE(ac.cross_revenue, '{}'::jsonb),
             la.d, li.items,
             COALESCE(cp.lvl, COALESCE(f.lvl, '一般會員')),
             #{rank_case.("COALESCE(cp.lvl, f.lvl, '一般會員')")} > #{rank_case.("COALESCE(f.lvl, '一般會員')")},
             cp.id, NULLIF(cp.full_name, ''), NULLIF(LOWER(TRIM(cp.instagram_account)), ''), NOW(),
             COALESCE(sf.fams, ARRAY[]::varchar[])
      FROM firsts f
      JOIN src s ON s.ik = f.ik
      LEFT JOIN first_items fi ON fi.ik = f.ik
      LEFT JOIN lasts la ON la.ik = f.ik
      LEFT JOIN last_items li ON li.ik = f.ik
      LEFT JOIN after_orders ao ON ao.ik = f.ik
      LEFT JOIN after_cross ac ON ac.ik = f.ik
      LEFT JOIN cust_pick cp ON cp.ik = f.ik
      LEFT JOIN second_fams sf ON sf.ik = f.ik
    SQL
  end
end
