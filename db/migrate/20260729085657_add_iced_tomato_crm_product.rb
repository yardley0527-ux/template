# frozen_string_literal: true

# 「冰晶番茄」已是 message_template / customer_profile 標籤系統認可的產品名稱
# （見 app/models/customer_profile.rb、app/models/message_template.rb），但 crm_products
# 一直沒有對應的 confirmed row，導致它出不現在直播「本場銷售產品」勾選清單（該清單
# 讀 CrmProduct.for_analysis）。這裡直接以 confirmed + include_in_analysis 補上一筆。
class AddIcedTomatoCrmProduct < ActiveRecord::Migration[7.1]
  KEY   = "iced_tomato"
  LABEL = "冰晶番茄"

  def up
    return if select_value("SELECT 1 FROM crm_products WHERE key = #{quote(KEY)}")

    execute <<~SQL
      INSERT INTO crm_products
        (key, label, status, include_in_analysis, source, regex_pattern, sql_pattern, availability_status, created_at, updated_at)
      VALUES
        (#{quote(KEY)}, #{quote(LABEL)}, 'confirmed', true, 'manual_addition',
         #{quote("#{LABEL}(\\d+)")}, #{quote("product_name LIKE '%#{LABEL}%'")}, 'unknown', NOW(), NOW())
    SQL
  end

  def down
    execute "DELETE FROM crm_products WHERE key = #{quote(KEY)}"
  end
end
