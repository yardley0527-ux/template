# path: app/services/page_registry.rb
# frozen_string_literal: true

# Derives the canonical list of manageable "pages" (controllers) straight from
# SidebarEntry, so the permissions admin UI and the sidebar filter never drift
# out of sync with each other.
class PageRegistry
  # Devise's own controllers must never be gated by page_permissions: Warden's
  # Database Authenticatable strategy authenticates as a side effect of the
  # inherited authenticate_user! before_action (it runs on any request carrying
  # user[username]/user[password] params), so by the time authorize_page! runs
  # during the sessions#create request itself, current_user is already present
  # and gets checked against the "sessions" controller — which no role should
  # ever need to whitelist just to be able to log in.
  ALWAYS_ALLOWED_CONTROLLERS = %w[welcome sessions passwords].freeze

  class << self
    # [{ group_title:, pages: [{ controller:, title: }] }]
    def groups
      @groups ||= SidebarEntry.all.filter_map do |group|
        pages = flatten(group[:children])
        next if pages.empty?

        { group_title: group[:group_title], pages: pages }
      end
    end

    def all_controllers
      @all_controllers ||= groups.flat_map { |g| g[:pages].map { |p| p[:controller] } }.uniq
    end

    def controller_for(href)
      path = href.to_s.split("?").first
      return nil if path.blank? || path == "#"

      Rails.application.routes.recognize_path(path, method: :get)[:controller]
    rescue ActionController::RoutingError
      nil
    end

    private

    def flatten(children)
      children.flat_map do |child|
        controller = controller_for(child[:href])
        own = controller ? [{ controller: controller, title: child[:title] }] : []
        child[:children].present? ? own + flatten(child[:children]) : own
      end.uniq { |p| p[:controller] }
    end
  end
end
