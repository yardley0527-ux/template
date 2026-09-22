# 合約狀態頁：從 KOC 業配名單拉出「合作中」的人。財務部登記合約寄出／收到
# 日期，社群部登記影片上架時間／廣告區間；兩邊都能看到整頁，但欄位各自
# 只能改自己負責的部分，不讓財務碰社群維護的欄位，反之亦然（其他 KOC 欄位
# 仍然只在 app/controllers/kocs_controller.rb 那邊維護）。
class KocContractsController < ApplicationController
  def index
    @kocs = Koc.visible.where(status: "合作中").order(:ig_username)
  end

  def update
    @koc = Koc.find(params[:id])
    @koc.update(koc_contract_params)
    redirect_back fallback_location: koc_contracts_path, allow_other_host: false, notice: "已更新 #{@koc.ig_username}"
  end

  private

  def koc_contract_params
    permitted = params.require(:koc).permit(:contract_sent_at, :contract_received_at, :video_posted_at, :ad_start_at, :ad_end_at)
    return permitted.slice(:contract_sent_at, :contract_received_at) if current_user.role&.key == "finance"
    return permitted.slice(:video_posted_at, :ad_start_at, :ad_end_at) if current_user.role&.key == "social"

    permitted
  end
end
