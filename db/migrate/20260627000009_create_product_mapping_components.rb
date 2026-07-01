# frozen_string_literal: true

# Epic C Phase 3A — Bundle SKU multi-product support.
# Allows one product_name_mapping (raw SKU) to be associated with multiple
# CrmProducts.  The existing product_name_mappings.crm_product_id column is
# retained as the "primary" product; this table holds the secondary ones.
#
# Example:
#   raw_name: "代謝錠1薑黃1"
#   crm_product_id (primary): metabolism
#   components: metabolism qty=1, turmeric qty=1
class CreateProductMappingComponents < ActiveRecord::Migration[7.1]
  def change
    create_table :product_mapping_components do |t|
      t.references :product_name_mapping, null: false, foreign_key: true,
                   index: false  # covered by compound indexes below
      t.references :crm_product,          null: false, foreign_key: true
      t.integer    :quantity,             null: false, default: 1
      t.timestamps
    end

    # Primary lookup: "which mappings contain crm_product X?" (used by orders_for)
    add_index :product_mapping_components,
              %i[crm_product_id product_name_mapping_id],
              unique: true,
              name: "idx_pmc_product_mapping"

    # Secondary lookup: "which components does mapping M have?"
    add_index :product_mapping_components,
              :product_name_mapping_id,
              name: "idx_pmc_mapping_id"
  end
end
