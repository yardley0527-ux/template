# frozen_string_literal: true

# 贈品訊息（custom_gift）的兩個子分類「會員小物」「禮物」合併為「會員小物、禮物」，
# 對應 HighValueOrderCustomMessagesController::SEND_PRODUCT_ITEMS 的改名——
# 不搬資料的話，既有模板會因 in_category 用 subcategory 精確比對而消失。
#
# 位置重排：兩個子分類各自有 0 起算的 position，直接合併會撞號，
# 因此以「會員小物在前、禮物在後」重新編號。
class MergeCustomGiftSubcategories < ActiveRecord::Migration[7.1]
  MERGED = "會員小物、禮物"

  def up
    execute <<~SQL
      WITH ordered AS (
        SELECT id, ROW_NUMBER() OVER (
          ORDER BY CASE subcategory WHEN '會員小物' THEN 0 ELSE 1 END, position, id
        ) - 1 AS rn
        FROM message_templates
        WHERE category_key = 'custom_gift' AND subcategory IN ('會員小物', '禮物')
      )
      UPDATE message_templates m
      SET subcategory = #{quote(MERGED)}, position = ordered.rn, updated_at = NOW()
      FROM ordered
      WHERE m.id = ordered.id
    SQL
  end

  # 無法還原原本「會員小物／禮物」的歸屬，全部退回「會員小物」。
  def down
    execute <<~SQL
      UPDATE message_templates
      SET subcategory = '會員小物', updated_at = NOW()
      WHERE category_key = 'custom_gift' AND subcategory = #{quote(MERGED)}
    SQL
  end
end
