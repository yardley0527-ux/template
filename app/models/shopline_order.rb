# path: app/models/shopline_order.rb
class ShoplineOrder < ApplicationRecord
  self.table_name = "shopline_orders"

  belongs_to :shopline_customer, optional: true
  belongs_to :import_run, optional: true

  # Per-order total: prefer the order-level total_amount (repeated on every line),
  # else fall back to summing the itemized checkout_amount across the order's lines.
  TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(total_amount, 0))
      ELSE SUM(COALESCE(checkout_amount, 0))
    END
  SQL

  # Valid paid orders only — order_status is always NULL in this dataset
  scope :valid_paid, -> {
    where(payment_status: "已付款")
      .where.not(order_number: [nil, ""])
      .where.not(email: [nil, ""])
      .where.not(order_date: nil)
  }
end
