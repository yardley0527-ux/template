# 財務部合約狀態頁：從 KOC 業配名單拉出「合作中」的人，只給財務部打合約寄出／
# 收到日期，不讓財務碰社群/物流部維護的其他 KOC 欄位（見 app/controllers/kocs_controller.rb）。
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
    params.require(:koc).permit(:contract_sent_at, :contract_received_at, :video_posted_at, :ad_start_at, :ad_end_at)
  end
end
