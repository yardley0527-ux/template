# KOC 名單頁（/kocs 與各品牌 /xxx_kocs）共用的公關品寄送紀錄：新增、刪除、統計。
# 放在各名單 controller 裡，沿用該頁的頁面權限；編輯權限跟物流部欄位相同（can_edit_logistics_fields?）。
module KocGiftShipmentActions
  extend ActiveSupport::Concern

  def create_gift_shipment
    return head :forbidden unless can_edit_logistics_fields?

    koc = gift_recipient_class.find(params[:id])
    shipment = koc.gift_shipments.new(params.require(:gift_shipment).permit(:shipped_on, :items, :notes))
    shipment.created_by_user_id = current_user.id
    if shipment.save
      redirect_back fallback_location: url_for(action: :index), allow_other_host: false, notice: "已新增 #{koc.ig_username} 的公關品寄送紀錄"
    else
      redirect_back fallback_location: url_for(action: :index), allow_other_host: false, alert: "請填寄出日期"
    end
  end

  def destroy_gift_shipment
    return head :forbidden unless can_edit_logistics_fields?

    koc = gift_recipient_class.find(params[:id])
    koc.gift_shipments.find(params[:shipment_id]).destroy!
    redirect_back fallback_location: url_for(action: :index), allow_other_host: false, notice: "已刪除 #{koc.ig_username} 的一筆公關品寄送紀錄"
  end

  private

  # kocs → Koc、relove_kocs → ReloveKoc
  def gift_recipient_class
    controller_name.classify.constantize
  end

  def load_gift_shipment_stats
    scope = KocGiftShipment.where(recipient_type: gift_recipient_class.name)
    @shipment_total = scope.count
    @repeat_shipped_count = scope.group(:recipient_id).having("COUNT(*) > 1").count.size
  end
end
