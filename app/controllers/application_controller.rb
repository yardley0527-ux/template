class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  after_action  :track_page_view

  private

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
