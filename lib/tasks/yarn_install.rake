Rake::Task['assets:precompile'].enhance(['yarn:install'])

namespace :yarn do
  task :install do
    system('yarn install --frozen-lockfile') || raise('yarn install failed')
  end
end
