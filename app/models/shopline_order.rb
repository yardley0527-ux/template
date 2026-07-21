# path: app/models/shopline_order.rb
class ShoplineOrder < ApplicationRecord
  self.table_name = "shopline_orders"

  belongs_to :shopline_customer, optional: true
  belongs_to :import_run, optional: true

  # Identifies a unique order line item by its actual content (order number +
  # product + quantity + checkout amount + occurrence), independent of where
  # it happened to sit in a spreadsheet. Used as the basis for source_row_hash
  # so re-importing the same order line updates the existing row instead of
  # creating a duplicate.
  #
  # total_amount is deliberately EXCLUDED from this identity. It was included
  # until 2026-07, which caused ~1,100 duplicate rows: the same real order
  # line re-exported by Shopline at a later date sometimes has total_amount
  # populated and sometimes blank (observed 100% directional: older export
  # had a value, newer export was NULL for the same line) — because the hash
  # changed, find_or_initialize_by inserted a second row instead of updating
  # the first. total_amount continues to be *stored* on the row (whichever
  # import last supplied a non-blank value wins — see the call site's
  # `payload.compact`, which never overwrites a known value with a blank one)
  # — it just no longer participates in identity.
  #
  # occurrence disambiguates genuinely repeated identical line items within
  # the same order_number (e.g. two separate "清纖粉2" lines in one order):
  # callers must pass a 1-based index counting prior lines in *this import
  # run* with the same (order_number, product_name, quantity,
  # checkout_amount) signature, in the order they appear in the source file.
  # This is the best available stand-in for a stable line-item id — the
  # Shopline export has no line_item_id/sku/variant_id column at all, so two
  # truly-identical lines cannot be told apart by content alone; occurrence
  # relies on the exported row order being stable run-to-run for the same
  # underlying order, which holds for byte-identical re-exports. If Shopline
  # ever reorders identical-content lines within an order between exports,
  # this can misassign *which* row is "occurrence 1" vs "2" — but since both
  # rows have identical content, that mix-up has no observable effect on any
  # query or report (see ShoplineOrder.content_hash spec for the reasoning).
  def self.content_hash(order_number:, product_name:, quantity:, checkout_amount:, occurrence: 1)
    Digest::SHA256.hexdigest(
      JSON.generate(
        order_number: order_number.to_s.strip,
        product_name: normalize_product_name(product_name),
        quantity: quantity.to_i,
        checkout_amount: format_decimal(checkout_amount),
        occurrence: occurrence.to_i
      )
    )
  end

  # Whitespace-only normalization — never touches digits or CJK content, so
  # it cannot make two different products hash the same. Strips incidental
  # double-spacing/leading-trailing whitespace that copy-paste or Excel
  # sometimes introduces around an otherwise-identical product name.
  def self.normalize_product_name(name)
    name.to_s.strip.gsub(/\s+/, " ")
  end

  def self.format_decimal(v)
    return "" if v.nil?
    # Strip thousands separators/whitespace ("2,980" / " 2980 ") and round to
    # the shopline_orders decimal column scale (2) before hashing, so
    # re-exports with formatting or sub-cent floating-point noise still hash
    # identically and update the existing row instead of inserting a
    # duplicate.
    cleaned = v.to_s.strip.delete(",")
    return "" if cleaned.blank?

    BigDecimal(cleaned).round(2).to_s("F")
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
