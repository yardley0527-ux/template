class OrderGiftRecordsController < ApplicationController
  def upsert
    record = OrderGiftRecord.find_or_initialize_by(order_number: params[:order_number])
    record.assign_attributes(gift_params)
    record.save!
    render json: { ok: true, gift_sent: record.gift_sent, gift_note: record.gift_note, custom_message_sent: record.custom_message_sent, follow_up_note: record.follow_up_note, first_purchase_message_sent: record.first_purchase_message_sent, ig_tagged: record.ig_tagged, community_maintenance_message_sent: record.community_maintenance_message_sent, health_card_sent: record.health_card_sent, care_message_sent: record.care_message_sent }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def gift_params
    params.require(:order_gift_record).permit(:gift_sent, :gift_note, :custom_message_sent, :follow_up_note, :first_purchase_message_sent, :ig_tagged, :community_maintenance_message_sent, :health_card_sent, :care_message_sent)
  end
end
