# path: app/services/importing/canceled_order_candidates.rb

module Importing
  # Shopline's export never marks a cancellation status on a row — a paid
  # order that gets canceled later is simply absent from the next export.
  # So for a given source_year/source_month, "still 已付款 in the DB but not
  # touched by the most recent import run covering that period" is the best
  # available signal that an order was paid, later canceled, and never
  # removed from shopline_orders.
  #
  # Used both by PaidOrdersWorkbookImporter (to print candidates right after
  # an import) and by the standalone `import:purge_canceled_orders` rake task
  # (to recompute the same set independently, any time later).
  class CanceledOrderCandidates
    def self.call(year:, month:)
      latest_run_id = ShoplineOrder.where(source_year: year, source_month: month).maximum(:import_run_id)
      return ShoplineOrder.none if latest_run_id.nil?

      ShoplineOrder
        .where(source_year: year, source_month: month, payment_status: "已付款")
        .where.not(import_run_id: latest_run_id)
        .order(:order_number)
    end
  end
end
