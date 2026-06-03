class HighSpenderFollowUpsController < ApplicationController
  def create
    HighSpenderFollowUp.create!(
      identity_key:   params[:identity_key],
      note:           params[:note].to_s.strip,
      followed_up_at: Time.current
    )
    redirect_back(fallback_location: high_spender_first_purchase_path)
  end
end
