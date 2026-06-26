# frozen_string_literal: true

# One component entry within a bundle SKU mapping.
# A ProductNameMapping may have multiple components when the raw product name
# represents a bundle (e.g. "代謝錠1薑黃1" → metabolism + turmeric).
#
# The ProductNameMapping.crm_product_id column is the PRIMARY product; this
# table holds ALL products in the bundle (including the primary one, allowing
# quantity to be recorded per product).
class ProductMappingComponent < ApplicationRecord
  belongs_to :product_name_mapping
  belongs_to :crm_product

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :product_name_mapping_id, uniqueness: { scope: :crm_product_id,
    message: "already has a component for this product" }
end
