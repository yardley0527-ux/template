# frozen_string_literal: true

# Fix the collagen (膠原飲) regex_pattern so it matches all product-name variants:
#   - 膠原N          (bare form, no suffix)
#   - 膠原飲N        (the canonical product name suffix)
#   - 膠原蛋白N      (collagen-protein form, common in bundles)
#   - 膠原蛋白飲N    (full combined form)
#
# The old pattern /膠原(\d+)/ required digits immediately after 膠原 and therefore
# failed to match 膠原蛋白1, causing 美白1膠原蛋白1 to be misclassified as a single
# product instead of a bundle in ProductNameMappingReviewReportService.
#
# The new pattern uses an optional non-capturing group for 蛋白 so that both
# 膠原N (short form) and 膠原蛋白N (full name) are matched. 膠原飲 is excluded
# because that product variant does not exist in this store.
class FixCollagenRegexPattern < ActiveRecord::Migration[7.1]
  OLD_PATTERN = '膠原(\d+)'
  NEW_PATTERN = '膠原(?:蛋白)?(\d+)'

  def up
    execute <<~SQL
      UPDATE crm_products
      SET regex_pattern = #{quote(NEW_PATTERN)},
          updated_at    = NOW()
      WHERE key = 'collagen'
        AND regex_pattern = #{quote(OLD_PATTERN)}
    SQL
  end

  def down
    execute <<~SQL
      UPDATE crm_products
      SET regex_pattern = #{quote(OLD_PATTERN)},
          updated_at    = NOW()
      WHERE key = 'collagen'
        AND regex_pattern = #{quote(NEW_PATTERN)}
    SQL
  end
end
