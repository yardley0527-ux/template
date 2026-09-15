# frozen_string_literal: true

# 全站「新客／舊客」的單一定義來源。
#
# 2026-07-14 已決議（見記憶 daily-orders-flow-tree）：新客定義統一用
# 「email 有無歷史已付款訂單」，不看會員卡別——當時是「決議、程式待改」，
# HighValueOrderScoping#select_old_orders 仍是卡別版舊定義，故意不動它
# （改變既有頁面數字不在這次任務範圍），但任何新程式碼一律呼叫這裡，
# 不要再各自重寫一份定義。
#
# 具體判斷：customer_purchase_summaries.first_date 落在期間內 = 該期間內的
# 新客（這是他第一次有效付款訂單）；first_date 早於期間起點 = 舊客回購；
# 找不到 first_date（尚未 refresh 或資料缺漏）一律不算新客，因為「這期間
# 是不是他第一次」無法確認時，不能武斷認定——由呼叫端決定要不要另外統計
# 缺資料的筆數。
class NewCustomerDefinition
  # email 可能因為手機號碼合併等原因對應到一筆以上的 identity_key /
  # customer_purchase_summaries 列；一律取最早的 first_date 代表這個 email
  # 真正第一次付款的時間點。
  def self.first_purchase_dates(emails)
    emails = Array(emails).uniq.reject(&:blank?)
    return {} if emails.empty?

    CustomerPurchaseSummary.where(email: emails)
                            .group(:email)
                            .minimum(:first_date)
                            .transform_values { |v| v&.to_date }
  end

  def self.new_in_period?(first_purchase_date, period_start, period_end)
    return false if first_purchase_date.nil?

    first_purchase_date.between?(period_start.to_date, period_end.to_date)
  end
end
