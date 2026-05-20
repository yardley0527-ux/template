namespace :ig do
  desc "Scrape an Instagram profile (usage: rake ig:scrape[username])"
  task :scrape, [:username] => :environment do |_, args|
    username = args[:username].presence || "chloechao0527"
    puts "Scraping @#{username}..."
    success = IgScraperService.scrape(username)
    puts success ? "Done." : "Failed — check logs."
  end
end
