# path: app/services/page_registry.rb
# frozen_string_literal: true

# Resolves sidebar hrefs to controller names, so the sidebar filter (SidebarEntry)
# and the page-level authorization check (ApplicationController#authorize_page!)
# agree on what a "page" is without hardcoding controller names in either place.
class PageRegistry
  # Devise's own controllers must never be gated by page_permissions: Warden's
  # Database Authenticatable strategy authenticates as a side effect of the
  # inherited authenticate_user! before_action (it runs on any request carrying
  # user[username]/user[password] params), so by the time authorize_page! runs
  # during the sessions#create request itself, current_user is already present
  # and gets checked against the "sessions" controller — which no role should
  # ever need to whitelist just to be able to log in.
  # calendar_events 是全公司共用的行事曆公佈欄，每個部門登入都要看得到，
  # 所以不走 page_permissions。
  ALWAYS_ALLOWED_CONTROLLERS = %w[welcome sessions passwords calendar_events].freeze

  class << self
    def controller_for(href)
      path = href.to_s.split("?").first
      return nil if path.blank? || path == "#"

      Rails.application.routes.recognize_path(path, method: :get)[:controller]
    rescue ActionController::RoutingError
      nil
    end
  end
end
