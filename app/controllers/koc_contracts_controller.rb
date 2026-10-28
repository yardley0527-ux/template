# 合約狀態頁：從 KOC 業配名單拉出「合作中」的人。財務部登記合約寄出／收到
# 日期，社群部登記影片上架時間／廣告區間；兩邊都能看到整頁，但欄位各自
# 只能改自己負責的部分，不讓財務碰社群維護的欄位，反之亦然（其他 KOC 欄位
# 仍然只在 app/controllers/kocs_controller.rb 那邊維護）。
class KocContractsController < ApplicationController
  def index
    # 勾了已付款的人（已合作、已匯款）還留在這頁，要等勾「已完成」才移出
    @kocs = Koc.visible.where(status: ["合作中", "已合作、已匯款"], contract_completed: false).order(:ig_username)
  end

  def update
    @koc = Koc.find(params[:id])
    if params.dig(:koc, :paid) == "1"
      # 財務勾「已付款」：聯絡狀態推進到「已合作、已匯款」，人還留在這頁；要先填付款時間
      if @koc.paid_at.blank?
        return redirect_back fallback_location: koc_contracts_path, allow_other_host: false, alert: "請先填 #{@koc.ig_username} 的付款時間，再勾已付款"
      end
      @koc.update(status: "已合作、已匯款") if can_mark_paid?
    elsif params.dig(:koc, :contract_completed) == "1"
      # 勾「已完成」才把人移出這頁
      @koc.update(contract_completed: true) if can_mark_paid?
    else
      @koc.update(koc_contract_params)
    end
    redirect_back fallback_location: koc_contracts_path, allow_other_host: false, notice: "已更新 #{@koc.ig_username}"
  end

  private

  def can_mark_paid?
    current_user.admin? || current_user.role&.key == "finance"
  end

  def koc_contract_params
    permitted = params.require(:koc).permit(:contract_sent_at, :contract_received_at, :video_posted_at, :ad_start_at, :ad_end_at, :paid_at)
    return permitted.slice(:contract_sent_at, :contract_received_at, :paid_at) if current_user.role&.key == "finance"
    return permitted.slice(:video_posted_at, :ad_start_at, :ad_end_at) if current_user.role&.key == "social"

    permitted
  end
end
