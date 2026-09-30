# frozen_string_literal: true

# 客人的公關品紀錄（新增／修改／刪除）。只有 owner（admin）可以動；
# 其他人在客戶頁只能看到清單。
class PrGiftsController < ApplicationController
  OTHER_PRODUCT = "__other__"

  before_action :require_owner!
  before_action :set_customer
  before_action :set_gift, only: %i[update destroy]

  def create
    gift = @customer.pr_gifts.new(gift_attributes.merge(created_by: current_user.username))
    if gift.save
      redirect_back_to_customer notice: "已新增公關品：#{gift.summary}"
    else
      redirect_back_to_customer alert: "公關品沒有存到：#{gift.errors.full_messages.to_sentence}"
    end
  end

  def update
    if @gift.update(gift_attributes)
      redirect_back_to_customer notice: "已更新公關品：#{@gift.summary}"
    else
      redirect_back_to_customer alert: "公關品沒有更新：#{@gift.errors.full_messages.to_sentence}"
    end
  end

  def destroy
    @gift.destroy
    redirect_back_to_customer notice: "已刪除公關品：#{@gift.summary}"
  end

  private

  def require_owner!
    return if current_user.admin?

    redirect_to root_path, alert: "只有老闆（管理員）可以編輯公關品紀錄"
  end

  def set_customer
    @customer = ShoplineCustomer.find(params[:customer_id])
  end

  def set_gift
    @gift = @customer.pr_gifts.find(params[:id])
  end

  # 下拉選「其他」時，產品名稱改用自己輸入的那格
  def gift_attributes
    raw = params.require(:pr_gift).permit(:product_name, :product_other, :quantity, :unit, :given_on, :note)
    attrs = raw.except(:product_other).to_h
    attrs["product_name"] = raw[:product_other].to_s.strip if raw[:product_name] == OTHER_PRODUCT
    attrs["given_on"] = Date.current if attrs["given_on"].blank?
    attrs
  end

  def redirect_back_to_customer(flash_opts)
    redirect_to customer_path(@customer, anchor: "pr-gifts"), flash_opts
  end
end
