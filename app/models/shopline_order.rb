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

  # Collapses "same real order line, landed as two rows because Shopline's
  # own 商品名稱 text for it drifted between two different import runs" (a
  # later export can add a gift suffix like "送1", fix a typo, or swap in a
  # short SKU code for a long product title — see content_hash's docstring).
  # That text is part of content_hash, so a drift makes source_row_hash miss
  # on find_or_initialize_by and land as a new row instead of updating the
  # old one, leaving the old row an orphan with the same (order_number,
  # quantity, checkout_amount) but different product_name.
  #
  # Any aggregation that sums quantity/checkout_amount per product without
  # first collapsing by order_number (unlike the MAX(total_amount) GROUP BY
  # order_number pattern used for order-level totals elsewhere in this app)
  # double-counts these orphans. Use this scope before doing that kind of
  # line-item-level SUM.
  #
  # Deliberately keyed on (order_number, quantity, checkout_amount) WITHOUT
  # product_name, but only drops a row when its group also spans more than
  # one import_run_id — measured on production: 379 groups fit that (true
  # drift, one row per import_run_id, keep only the most recent); a much
  # larger 507 groups share identical (order_number, quantity,
  # checkout_amount) with *different* product_name but the *same*
  # import_run_id — genuinely distinct line items in one order that happen
  # to coincide on quantity/amount (e.g. two different $0 gift lines), not a
  # drift artifact, and this scope leaves every row in those groups alone.
  # A group with only one product_name (a single line, or a genuine
  # occurrence-based repeat of the same line — see content_hash's docstring)
  # is never touched either way.
  scope :dedup_content_drift, -> {
    joins(<<~SQL.squish)
      INNER JOIN (
        SELECT order_number, quantity, checkout_amount,
               COUNT(DISTINCT product_name) AS distinct_names,
               MAX(import_run_id) AS max_run
        FROM shopline_orders
        GROUP BY order_number, quantity, checkout_amount
      ) content_drift_groups
        ON content_drift_groups.order_number = shopline_orders.order_number
       AND content_drift_groups.quantity = shopline_orders.quantity
       AND content_drift_groups.checkout_amount = shopline_orders.checkout_amount
    SQL
      .where(
        "content_drift_groups.distinct_names = 1 OR shopline_orders.import_run_id = content_drift_groups.max_run"
      )
  }
end
