# lib/tasks/customer_series_loyalty.rake
namespace :customer_series_loyalty do
  desc "Refresh customer series loyalty table"
  task refresh: :environment do
    CustomerSeriesLoyaltyRefreshService.call
    puts "customer_series_loyalties refreshed"
  end
end