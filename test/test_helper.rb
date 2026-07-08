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
  # Parallelization disabled: activesupport 7.1.6's parallelization worker
  # calls Minitest.run_one_method, which minitest 6.0.1 removed/renamed (same
  # class of incompatibility as the LineFiltering patch above). This was
  # latent — the suite stayed under Rails' default 50-test parallelization
  # threshold until Epic E3-2 pushed it past that, which is what surfaced it.
  # workers: 1 sidesteps the broken fork path entirely; at this suite size
  # single-process is still well under a second.
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
