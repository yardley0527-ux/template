namespace :yardley do
  desc "Scrape yardley.tw product listing and record a promotion snapshot per JourneyProducts key"
  task scrape_promotions: :environment do
    success = YardleyPromotionScraperService.call
    puts success ? "Done." : "Failed — check logs."
  end
end
