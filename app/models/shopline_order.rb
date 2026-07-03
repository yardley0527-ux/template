# path: app/models/shopline_order.rb
class ShoplineOrder < ApplicationRecord
  self.table_name = "shopline_orders"

  belongs_to :shopline_customer, optional: true
  belongs_to :import_run, optional: true

  # Identifies a unique order line item by its actual content (order number +
  # product + quantity + amounts), independent of where it happened to sit in
  # a spreadsheet. Used as the basis for source_row_hash so re-importing the
  # same order line updates the existing row instead of creating a duplicate.
  def self.content_hash(order_number:, product_name:, quantity:, checkout_amount:, total_amount:)
    Digest::SHA256.hexdigest(
      JSON.generate(
        order_number: order_number.to_s.strip,
        product_name: product_name.to_s.strip,
        quantity: quantity.to_i,
        checkout_amount: format_decimal(checkout_amount),
        total_amount: format_decimal(total_amount)
      )
    )
  end

  def self.format_decimal(v)
    return "" if v.nil?
    BigDecimal(v.to_s).to_s("F")
  rescue ArgumentError
    ""
  end

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
