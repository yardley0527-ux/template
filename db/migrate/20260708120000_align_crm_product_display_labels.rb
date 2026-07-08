# frozen_string_literal: true

# Display-label cleanup: align the two CrmProduct labels that had diverged
# from the series names every cached analytics table already uses
# (customer_series_loyalties.series / customer_purchase_summaries.first_series
# are built from SERIES_OPTIONS, which says 全能 / 膠原蛋白).
#
#   collagen:   膠原飲   → 膠原蛋白
#   omnipotent: B群／全能 → 全能
#
# Scope guard — this migration touches ONLY crm_products.label:
#   - key, aliases, regex_pattern, sql_pattern unchanged
#   - product_name_mappings / product_mapping_components unchanged
#
# The WHERE clause pins both key AND current label, so a row a human has
# already renamed to something else is left alone (and the migration is
# idempotent). CrmProduct::SERIES_FILTER_OVERRIDES bridged this divergence
# for filter dropdowns and becomes a no-op once this runs.
class AlignCrmProductDisplayLabels < ActiveRecord::Migration[7.1]
  RENAMES = [
    { key: "collagen",   from: "膠原飲",    to: "膠原蛋白" },
    { key: "omnipotent", from: "B群／全能", to: "全能" },
  ].freeze

  def up
    RENAMES.each do |r|
      execute <<~SQL
        UPDATE crm_products
        SET label = #{quote(r[:to])}, updated_at = NOW()
        WHERE key = #{quote(r[:key])} AND label = #{quote(r[:from])}
      SQL
    end
  end

  def down
    RENAMES.each do |r|
      execute <<~SQL
        UPDATE crm_products
        SET label = #{quote(r[:from])}, updated_at = NOW()
        WHERE key = #{quote(r[:key])} AND label = #{quote(r[:to])}
      SQL
    end
  end
end
