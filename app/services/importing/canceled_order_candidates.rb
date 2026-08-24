# path: app/services/importing/canceled_order_candidates.rb

module Importing
  # Shopline's export never marks a cancellation status on a row — a paid
  # order that gets canceled later is simply absent from the next export.
  # So for a given source_year/source_month, "still 已付款 in the DB but not
  # touched by the most recent import run covering that period" is the best
  # available signal that an order was paid, later canceled, and never
  # removed from shopline_orders.
  #
  # Checked by order_number, not by individual row: Shopline's own
  # "商品名稱" text for an existing order is not stable across exports (a
  # later export can add gift/promo suffixes like "送1", fix a typo, or
  # swap in a short SKU code for a long product title). Since that text is
  # part of ShoplineOrder.content_hash, any of those edits makes the row's
  # source_row_hash miss on find_or_initialize_by and land as a *new* row
  # instead of updating the old one — leaving the old row an orphan that
  # still carries the same order_number. Checking row-level import_run_id
  # (as this used to) flags that orphan as "canceled" even though the order
  # is very much still in the latest file, just under a different row.
  # Measured on production 2026 data: 379 of 472 row-level "candidates" were
  # false positives of exactly this kind — checking by order_number instead
  # eliminates them without touching content_hash or the underlying
  # duplicate rows (that's a separate, harder cleanup problem).
  #
  # Used both by PaidOrdersWorkbookImporter (to print candidates right after
  # an import) and by the standalone `import:purge_canceled_orders` rake task
  # (to recompute the same set independently, any time later).
  class CanceledOrderCandidates
    def self.call(year:, month:)
      latest_run_id = ShoplineOrder.where(source_year: year, source_month: month).maximum(:import_run_id)
      return ShoplineOrder.none if latest_run_id.nil?

      touched_order_numbers = ShoplineOrder
        .where(source_year: year, source_month: month, import_run_id: latest_run_id)
        .select(:order_number)

      ShoplineOrder
        .where(source_year: year, source_month: month, payment_status: "已付款")
        .where.not(order_number: touched_order_numbers)
        .order(:order_number)
    end
  end
end
