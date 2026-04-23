class ExpiringMembersController < ApplicationController
  def index
    base = ShoplineCustomer.where.not(membership_expiry_date: nil)
                          .where(membership_expiry_date: Date.today..)
                          .where(membership_level: ["黑卡", "金卡"])
                          .order(:membership_expiry_date)

    @black_15 = base.where(membership_level: "黑卡", membership_expiry_date: ..15.days.from_now.to_date)
    @black_30 = base.where(membership_level: "黑卡", membership_expiry_date: 16.days.from_now.to_date..30.days.from_now.to_date)
    @gold_15  = base.where(membership_level: "金卡", membership_expiry_date: ..15.days.from_now.to_date)
    @gold_30  = base.where(membership_level: "金卡", membership_expiry_date: 16.days.from_now.to_date..30.days.from_now.to_date)
  end

  def confirm_renewal
    @customer = ShoplineCustomer.find(params[:id])
    profile = @customer.customer_profile || @customer.build_customer_profile
    profile.update!(
      renewal_confirmed_at: Time.current,
      renewal_confirmed_for: @customer.membership_expiry_date
    )
    redirect_back fallback_location: expiring_members_path
  end
end