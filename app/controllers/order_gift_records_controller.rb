class OrderGiftRecordsController < ApplicationController
  def upsert
    record = OrderGiftRecord.find_or_initialize_by(order_number: params[:order_number])
    record.assign_attributes(gift_params)
    record.save!
    render json: { ok: true, gift_sent: record.gift_sent, gift_note: record.gift_note, custom_message_sent: record.custom_message_sent, follow_up_note: record.follow_up_note, first_purchase_message_sent: record.first_purchase_message_sent, ig_tagged: record.ig_tagged, community_maintenance_message_sent: record.community_maintenance_message_sent, health_card_sent: record.health_card_sent, crm_maintenance_unread: record.crm_maintenance_unread, care_message_sent: record.care_message_sent }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def gift_params
    permitted = params.require(:order_gift_record).permit(:gift_sent, :gift_note, :custom_message_sent, :follow_up_note, :first_purchase_message_sent, :ig_tagged, :community_maintenance_message_sent, :health_card_sent, :crm_maintenance_unread, :care_message_sent)
    # social 角色在每日訂單頁只能勾「社群部維護訊息」，其他欄位即使被送進來也要濾掉
    return permitted.slice(:community_maintenance_message_sent) if current_user.role&.key == "social"
    # crm 角色在每日訂單頁只能勾「CRM維護已讀」／「CRM維護未讀」；只限定在 daily_orders 頁面送出的請求，
    # 避免波及 crm 角色在 high_value_orders/high_value_follow_ups 頁面共用同一支 endpoint 的完整編輯權限
    return permitted.slice(:health_card_sent, :crm_maintenance_unread) if current_user.role&.key == "crm" && params[:page] == "daily_orders"

    permitted
  end
end
