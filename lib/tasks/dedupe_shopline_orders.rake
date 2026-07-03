# path: lib/tasks/dedupe_shopline_orders.rake
# frozen_string_literal: true

namespace :dedupe do
  desc <<~DESC
    Recompute shopline_orders.source_row_hash from order content (order_number +
    product_name + quantity + amounts) instead of the old spreadsheet-row-position
    hash, and remove duplicate rows that share the same content hash.

    For each duplicate group, keeps the most-recently-created row and deletes the rest.

    Usage:
      DISABLE_SPRING=1 bundle exec rails "dedupe:shopline_orders[dry]"
      DISABLE_SPRING=1 bundle exec rails "dedupe:shopline_orders[run]"
  DESC
  task :shopline_orders, [:mode] => :environment do |_t, args|
    mode = (args[:mode].presence || "dry").to_s
    raise ArgumentError, "mode must be dry or run" unless %w[dry run].include?(mode)

    total = ShoplineOrder.count
    puts "[dedupe] mode=#{mode} total_orders=#{total}"

    groups = Hash.new { |h, k| h[k] = [] }

    ShoplineOrder.find_each(batch_size: 1000) do |order|
      hash = ShoplineOrder.content_hash(
        order_number: order.order_number,
        product_name: order.product_name,
        quantity: order.quantity,
        checkout_amount: order.checkout_amount,
        total_amount: order.total_amount
      )
      groups[hash] << order
    end

    duplicate_groups = groups.select { |_hash, rows| rows.size > 1 }
    rows_to_delete = duplicate_groups.values.sum { |rows| rows.size - 1 }

    puts "[dedupe] distinct_content_hashes=#{groups.size} duplicate_groups=#{duplicate_groups.size} rows_to_delete=#{rows_to_delete}"

    hash_updates = 0
    deleted = 0

    groups.each do |hash, rows|
      sorted = rows.sort_by(&:created_at)
      keep = sorted.last
      extras = sorted[0..-2]

      if mode == "run"
        keep.update_columns(source_row_hash: hash) unless keep.source_row_hash == hash
        extras.each(&:destroy!)
      end

      hash_updates += 1
      deleted += extras.size
    end

    puts "[dedupe] hash_updates=#{hash_updates} deleted=#{deleted}"
    puts "[dedupe] NOTE: run with mode=run to persist changes" if mode == "dry"
  end
end
