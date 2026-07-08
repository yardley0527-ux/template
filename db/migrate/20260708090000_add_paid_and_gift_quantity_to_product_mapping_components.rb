# frozen_string_literal: true

# Epic E3-1 — SKU Composition: split ProductMappingComponent#quantity into
# paid_quantity / gift_quantity, plus a generated total_quantity column.
#
# `quantity` is kept (not dropped) for one more release cycle as a rollback
# safety net — bundle_components.rake is the only write site and is updated
# in this same PR to write paid_quantity instead.
#
# Backfill is a straight copy (paid_quantity = quantity, gift_quantity stays
# at its default 0) for all pre-existing rows. This does NOT attempt to fix
# rows whose raw_name contains 送/贈, where the pre-E3 parser (BundleComponentParser)
# sometimes misparsed a gift item as a second paid component (e.g. "代謝錠12送全能2"
# currently stored as metabolism:12, omnipotent:2 — omnipotent should really be
# gift_quantity:2, paid_quantity:0). That reconciliation is deliberately deferred
# to E3-4, which re-parses with the new quantity/promotion-aware parser and diffs
# against existing rows before overwriting anything.
class AddPaidAndGiftQuantityToProductMappingComponents < ActiveRecord::Migration[7.1]
  def up
    add_column :product_mapping_components, :paid_quantity, :integer, null: false, default: 1
    add_column :product_mapping_components, :gift_quantity, :integer, null: false, default: 0
    add_column :product_mapping_components, :total_quantity, :virtual,
               type: :integer, as: "paid_quantity + gift_quantity", stored: true

    execute <<~SQL
      UPDATE product_mapping_components
      SET paid_quantity = quantity
    SQL
  end

  def down
    remove_column :product_mapping_components, :total_quantity
    remove_column :product_mapping_components, :gift_quantity
    remove_column :product_mapping_components, :paid_quantity
  end
end
