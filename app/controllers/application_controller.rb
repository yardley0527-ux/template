class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  before_action :authorize_page!
  after_action  :track_page_view

  helper_method :purchase_summary_updated_at, :series_loyalty_updated_at

  private

  def authorize_page!
    return if current_user.blank?
    return if PageRegistry::ALWAYS_ALLOWED_CONTROLLERS.include?(controller_name)
    return if current_user.admin?
    return if current_user.role&.page_permissions&.exists?(controller_name: controller_name)

    redirect_to root_path, alert: "您沒有權限存取此頁面"
  end

  def purchase_summary_updated_at
    Rails.cache.fetch("purchase_summary_updated_at", expires_in: 10.minutes) do
      CustomerPurchaseSummary.maximum(:updated_at)
    end
  end

  def series_loyalty_updated_at
    Rails.cache.fetch("series_loyalty_updated_at", expires_in: 10.minutes) do
      CustomerSeriesLoyalty.maximum(:updated_at)
    end
  end

  def track_page_view
    return unless PageView::TRACKED_CONTROLLERS.include?(controller_name)
    PageView.create!(
      controller_name: controller_name,
      action_name:     action_name,
      path:            request.path,
      user_id:         current_user&.id,
      visited_at:      Time.current
    )
  rescue StandardError
    # 追蹤失敗不能影響主功能
  end
end
