require "logger"
require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SmartadminRailsSeed
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 6.0

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration can go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded after loading
    # the framework and any gems in your application.

    config.app = 'SmartAdmin'
    config.version = '4.0.3'
    config.app_sidebar = true
    config.logo = 'logo.png'
    config.app_flavor = 'SmartAdmin on Rails'
    config.app_flavor_subscript = ''
    config.user = 'Dr. Codex Lantern'
    config.avatar = 'avatar-admin.png'
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
    config.copyright = "2020 © SmartAdmin on Rails by&nbsp;<a href='https://smartadmin-rails-full.herokuapp.com/' class='text-primary fw-500' title='gotbootstrap.com' target='_blank'>sildur</a>".html_safe
    config.copyright_inverse = "2020 © SmartAdmin on Rails by&nbsp;<a href='https://smartadmin-rails-full.herokuapp.com/' class='text-white opacity-40 fw-500' title='gotbootstrap.com' target='_blank'>sildur</a>".html_safe
    config.app_name = 'SmartAdmin WebApp'
    config.bs4v = '4.3'
    config.app_shortcut_modal = true
    config.sa_assets_prefix = 'smartadmin/'
    config.sa_asset_filetypes =
      %w(*.png *.jpg *.jpeg *.gif *.svg *.json *.webm *.mp4 *.js *.css)
  end
end
