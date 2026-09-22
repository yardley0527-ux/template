# frozen_string_literal: true

# 「PDRN」是 9/18 直播後新上市的品項（見 product_inventory_controller.rb 的
# 進貨計畫），crm_products 還沒有對應的 confirmed row，導致它出不現在每日訂單
# 明細頁的產品篩選下拉選單（該選單讀 CrmProduct.series_labels_for_filter）。
# 正式站訂單資料裡的 product_name 是 PDRN1/PDRN3/PDRN5/PDRN10 這種「PDRN+瓶數」格式，
# 比照冰晶番茄（見 20260729085657_add_iced_tomato_crm_product.rb）直接補一筆。
class AddPdrnCrmProduct < ActiveRecord::Migration[7.1]
  KEY   = "pdrn"
  LABEL = "PDRN"

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
