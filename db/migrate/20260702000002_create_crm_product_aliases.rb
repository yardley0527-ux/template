# frozen_string_literal: true

# Epic E1 — Product Alias Registry.
#
# Stores all known name variants for each CrmProduct (e.g. "代謝" and "代謝錠"
# both map to the metabolism product).  ProductAliasRegexGeneratorService reads
# active aliases and regenerates crm_products.regex_pattern automatically, so
# regex patterns no longer need to be hand-maintained.
class CreateCrmProductAliases < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_product_aliases do |t|
      t.references :crm_product, null: false, foreign_key: true

      # The exact alias as it appears in raw order names (e.g. "膠原蛋白").
      t.string :alias_name,       null: false

      # Normalised form used for deduplication (strip + NFC); derived from alias_name.
      t.string :normalized_alias, null: false

      t.string :status, null: false, default: "active"   # active | inactive
      t.string :source, null: false, default: "seed"     # seed | manual | generated
      t.text   :notes

      t.timestamps
    end

    # Uniqueness: one alias_name per product (case-sensitive).
    add_index :crm_product_aliases, [:crm_product_id, :alias_name],
              unique: true, name: "idx_crm_product_aliases_uniq"

    add_index :crm_product_aliases, :alias_name, name: "idx_crm_product_aliases_name"
    add_index :crm_product_aliases, :status,     name: "idx_crm_product_aliases_status"
  end
end
