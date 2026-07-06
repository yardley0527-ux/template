# path: app/services/page_registry.rb
# frozen_string_literal: true

# Derives the canonical list of manageable "pages" (controllers) straight from
# SidebarEntry, so the permissions admin UI and the sidebar filter never drift
# out of sync with each other.
class PageRegistry
  ALWAYS_ALLOWED_CONTROLLERS = %w[welcome].freeze

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
        if child[:children].present?
          flatten(child[:children])
        else
          controller = controller_for(child[:href])
          controller ? [{ controller: controller, title: child[:title] }] : []
        end
      end.uniq { |p| p[:controller] }
    end
  end
end
