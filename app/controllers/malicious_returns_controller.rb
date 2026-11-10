# frozen_string_literal: true

# 惡意退貨黑名單：財務退貨表上標「惡意退貨」的每一列、對到的客人、目前是否在黑名單。
# 資料來自 MaliciousReturnSync 最後一次同步（匯入訂單後與 rake ops:sync 自動跑），也可按「立即同步」。
class MaliciousReturnsController < ApplicationController
  def index
    @run = MaliciousReturnSync.latest_run
    @last_attempt = SyncRun.where(source: "malicious_returns").order(:created_at).last
    @entries = (@run&.meta || {}).fetch("entries", [])

    ids = @entries.flat_map { |e| e["customer_ids"] }.uniq
    @customers = ShoplineCustomer.where(id: ids).includes(:customer_profile).index_by(&:id)
    @auto_logged = CustomerEditLog.where(customer_id: ids, section: MaliciousReturnSync::LOG_SECTION)
                                  .pluck(:customer_id, :created_at).to_h
  end

  def sync
    result = MaliciousReturnSync.call
    if result[:error]
      redirect_to malicious_returns_path, alert: "同步失敗：#{result[:error]}"
    else
      notice = "同步完成：共 #{result[:rows]} 筆惡意退貨，新加入黑名單 #{result[:added].size} 人"
      notice += "，#{result[:unmatched].size} 筆對不到客人" if result[:unmatched].any?
      redirect_to malicious_returns_path, notice: notice
    end
  end
end
