class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  before_action :authorize_page!
  after_action  :track_page_view

  helper_method :purchase_summary_updated_at, :series_loyalty_updated_at

  # XHR 寫入端點掛在別的 controller 底下，權限要看「放這個元件的頁面」，
  # 不能看端點自己的 controller，否則有頁面權限的人存檔會被擋
  XHR_ENDPOINT_PAGES = {
    "daily_orders#toggle_customer_flag"  => %w[daily_orders high_value_orders customers],
    "daily_orders#update_customer_type"  => %w[daily_orders high_value_orders],
    "order_gift_records#upsert"          => %w[daily_orders high_value_orders high_value_follow_ups]
  }.freeze

  private

  def authorize_page!
    return if current_user.blank?
    return if PageRegistry::ALWAYS_ALLOWED_CONTROLLERS.include?(controller_name)
    return if current_user.admin?

    allowed = XHR_ENDPOINT_PAGES["#{controller_name}##{action_name}"] || [controller_name]
    return if current_user.role&.page_permissions&.exists?(controller_name: allowed)

    # 非 GET 多半是前端 fetch：回 403 讓 JS 顯示失敗，302 導首頁會被誤判成儲存成功
    if request.get?
      redirect_to root_path, alert: "您沒有權限存取此頁面"
    else
      head :forbidden
    end
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
