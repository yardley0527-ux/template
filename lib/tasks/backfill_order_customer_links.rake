# path: lib/tasks/backfill_order_customer_links.rake
# frozen_string_literal: true

namespace :backfill do
  desc <<~DESC
    Backfill shopline_customer_id for orders where it's NULL.

    Usage:
      DISABLE_SPRING=1 bundle exec rails "backfill:order_customer_links[dry]"
      DISABLE_SPRING=1 bundle exec rails "backfill:order_customer_links[run]"
  DESC
  task :order_customer_links, [:mode] => :environment do |_t, args|
    mode = (args[:mode].presence || "dry").to_s
    raise ArgumentError, "mode must be dry or run" unless %w[dry run].include?(mode)

    scope = ShoplineOrder.where(shopline_customer_id: nil)
    total = scope.count

    puts "[backfill] mode=#{mode} targets=#{total}"

    updated = 0
    missing = 0

    scope.find_each(batch_size: 500) do |order|
      email = ShoplineCustomer.normalize_email(order.email)
      ig = ShoplineCustomer.normalize_ig(order.instagram_account)

      customer =
        if email
          ShoplineCustomer.find_by(email: email)
        elsif ig
          ShoplineCustomer.find_by(instagram_account: ig)
        end

      unless customer
        missing += 1
        next
      end

      if mode == "run"
        order.update_columns(shopline_customer_id: customer.id, updated_at: Time.zone.now)
      end
      updated += 1
    end

    puts "[backfill] updated=#{updated} missing_match=#{missing} targets=#{total}"
    puts "[backfill] NOTE: run with mode=run to persist changes" if mode == "dry"
  end
end
