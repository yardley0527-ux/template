require 'logger'
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)

require 'bundler/setup' # Set up gems listed in the Gemfile.
require 'bootsnap/setup' # Speed up boot time by caching expensive operations.

require "yaml"
# This allows Ruby's YAML parser to handle aliases (& and *) 
# which are common in Rails database.yml files.
YAML::ENGINE.yamler = 'psych' if defined?(YAML::ENGINE)

require 'psych'
module Psych
  class << self
    alias_method :orig_safe_load, :safe_load
    def safe_load(yaml, **kwargs)
      orig_safe_load(yaml, **kwargs.merge(aliases: true))
    end
  end
end