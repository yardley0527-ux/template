# frozen_string_literal: true

# One row = one CrmProduct's SKU composition within a ProductNameMapping.
#
# This is NOT bundle-only: every confirmed mapping is expected to have at
# least one component, including single-product SKUs (e.g. "全能6" → one
# component row: omnipotent, paid_quantity: 6, gift_quantity: 0). A "bundle"
# is just the case where a mapping has more than one component — see
# ProductNameMapping#bundle?. Don't infer "component exists" to mean "bundle."
#
# paid_quantity / gift_quantity split what used to be a single `quantity`
# column (Epic E3-1) so promotional gift units ("送2", "贈1") can be counted
# separately from what was actually paid for. total_quantity is a generated
# column (paid_quantity + gift_quantity), kept in sync by Postgres so SUM()
# queries don't need to add the two in SQL.
#
# The ProductNameMapping.crm_product_id column is the PRIMARY product; this
# table holds ALL products referenced by the raw_name (including the primary
# one), each with its own quantity breakdown.
class ProductMappingComponent < ApplicationRecord
  belongs_to :product_name_mapping
  belongs_to :crm_product

  validates :paid_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :gift_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :paid_or_gift_quantity_present
  validates :product_name_mapping_id, uniqueness: { scope: :crm_product_id,
    message: "already has a component for this product" }

  private

  def paid_or_gift_quantity_present
    return if paid_quantity.to_i.positive? || gift_quantity.to_i.positive?

    errors.add(:base, "paid_quantity and gift_quantity cannot both be zero")
  end
end
