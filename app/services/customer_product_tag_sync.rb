# frozen_string_literal: true

# 依已付款訂單，自動幫客人補上「購買過苼莛的產品」標籤（customer_profiles.shengting_product_tags）。
#
# 只「補」不「刪」：客人手動勾過的標籤完全不動，只把買過、但還沒勾的產品加進去。
# 目前只管新品（PDRN／冰晶番茄），其他產品維持人工勾選；要擴充就加進 RULES。
# 冰晶番茄的訂單有「蕃茄」「番茄」兩種寫法，兩種都算。標籤文字沿用編輯頁選項
# （CustomerProfile::SHENGTING_PRODUCT_OPTIONS）。
#
# idempotent：重複執行不會重複加標籤。客人若還沒有 customer_profiles 紀錄會先建立空白紀錄。
class CustomerProductTagSync
  RULES = {
    "PDRN"     => %w[PDRN],
    "冰晶番茄" => %w[冰晶蕃茄 冰晶番茄]
  }.freeze

  def self.call
    new.call
  end

  # => { "PDRN" => { profiles_created: n, tags_added: n }, ... }
  def call
    conn = ActiveRecord::Base.connection
    ActiveRecord::Base.transaction do
      RULES.each_with_object({}) do |(tag, keywords), result|
        buyers_sql = buyer_customer_ids_sql(conn, keywords)

        created = conn.exec_update(<<~SQL)
          INSERT INTO customer_profiles (shopline_customer_id, created_at, updated_at)
          SELECT b.id, NOW(), NOW() FROM (#{buyers_sql}) b
          WHERE NOT EXISTS (SELECT 1 FROM customer_profiles cp WHERE cp.shopline_customer_id = b.id)
        SQL

        added = conn.exec_update(<<~SQL)
          UPDATE customer_profiles
          SET shengting_product_tags = array_append(shengting_product_tags, #{conn.quote(tag)})
          WHERE shopline_customer_id IN (#{buyers_sql})
            AND NOT (#{conn.quote(tag)} = ANY(shengting_product_tags))
        SQL

        result[tag] = { profiles_created: created, tags_added: added }
      end
    end
  end

  private

  def buyer_customer_ids_sql(conn, keywords)
    patterns = keywords.map { |k| conn.quote("%#{k}%") }.join(", ")
    <<~SQL.squish
      SELECT DISTINCT sc.id
      FROM shopline_orders so
      JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = LOWER(TRIM(so.email))
      WHERE so.payment_status = '已付款'
        AND so.email IS NOT NULL AND so.email <> ''
        AND so.product_name LIKE ANY (ARRAY[#{patterns}])
    SQL
  end
end
