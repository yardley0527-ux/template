ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

# minitest 6.0.1 changed Runnable#run to (suite, name, reporter) but railties 7.1.6
# LineFiltering still expects (reporter, options={}), causing an arity error.
# This patch lets minitest 6 call through unobstructed; line-level filtering is
# a dev convenience and not needed in CI.
Rails::LineFiltering.module_eval do
  def run(*args)
    super
  end
end

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
