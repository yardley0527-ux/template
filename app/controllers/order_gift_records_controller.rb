class OrderGiftRecordsController < ApplicationController
  def upsert
    record = OrderGiftRecord.find_or_initialize_by(order_number: params[:order_number])
    record.assign_attributes(gift_params)
    record.save!
    render json: { ok: true, gift_sent: record.gift_sent, gift_note: record.gift_note }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def gift_params
    params.require(:order_gift_record).permit(:gift_sent, :gift_note)
  end
end
