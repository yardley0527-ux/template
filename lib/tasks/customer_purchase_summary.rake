# lib/tasks/customer_purchase_summary.rake
namespace :customer_purchase_summary do
  desc "Refresh customer purchase summaries"
  task refresh: :environment do
    CustomerPurchaseSummaryRefreshService.call
    puts "customer_purchase_summaries refreshed"
  end
end