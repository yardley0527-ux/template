require "logger"
require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SmartadminRailsSeed
  class Application < Rails::Application
    config.load_defaults 7.1
    config.time_zone = 'Taipei'
    config.app = 'SmartAdmin'
    config.version = '4.0.3'
    config.app_sidebar = true
    config.logo = 'logo.png'
    config.app_flavor = '苼莛國際生技'
    config.app_flavor_subscript = ''
    config.user = 'Dr. Codex Lantern'
    config.avatar = 'logo.jpg'
    config.app_header = true
    config.app_layout_shortcut = true
    config.layout_settings = true
    config.chat_interface = true
    config.email = 'drlantern@gotbootstrap.com'
    config.twitter = 'codexlantern'
    config.shortcut_menu = true
    config.chat_interface = true
    config.layout_settings = true
    config.app_footer = true
    config.copyright = "2026 © 苼莛生技".html_safe
    config.copyright_inverse = "2026 © 苼莛生技".html_safe
    config.app_name = 'SmartAdmin WebApp'
    config.bs4v = '4.3'
    config.app_shortcut_modal = true
    config.sa_assets_prefix = 'smartadmin/'
    config.sa_asset_filetypes =
      %w(*.png *.jpg *.jpeg *.gif *.svg *.json *.webm *.mp4 *.js *.css)

    config.active_record.yaml_column_permitted_classes = [
      Symbol,
      Date,
      Time,
      ActiveSupport::TimeWithZone,
      ActiveSupport::TimeZone,
      ActiveSupport::HashWithIndifferentAccess
    ]
    config.autoload_paths << Rails.root.join("app/services")
    config.eager_load_paths << Rails.root.join("app/services")
  end
end
