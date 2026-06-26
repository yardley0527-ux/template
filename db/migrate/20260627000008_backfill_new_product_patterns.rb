# frozen_string_literal: true

# Backfill regex_pattern and sql_pattern for the 7 products created during
# the Product Dictionary Review (Epic B2 Phase 2).  The original 6 seeded
# products (omnipotent/metabolism/glutathione/collagen/turmeric/probiotic)
# already have these columns populated by ProductCandidateGeneratorService.
class BackfillNewProductPatterns < ActiveRecord::Migration[7.1]
  PATTERNS = {
    "whitening"          => { regex: '美白(\d+)',              sql: "product_name LIKE '%美白%'" },
    "fish_oil"           => { regex: '魚油(\d+)',              sql: "product_name LIKE '%魚油%'" },
    "cleanse_powder"     => { regex: '清纖粉(\d+)',            sql: "product_name LIKE '%清纖粉%'" },
    "astaxanthin"        => { regex: '蝦紅素(\d+)',            sql: "product_name LIKE '%蝦紅素%'" },
    "intimate_powder"    => { regex: '私密粉?(\d+)',           sql: "product_name LIKE '%私密%'" },
    "mask"               => { regex: '面(?:膜)?(\d+)',         sql: "product_name LIKE '%面膜%'" },
    "vitamin_dk_calcium" => { regex: '(?:維+)?DK鈣(\d+)',     sql: "product_name LIKE '%DK鈣%' OR product_name LIKE '%維DK鈣%'" }
  }.freeze

  def up
    PATTERNS.each do |key, attrs|
      execute <<~SQL
        UPDATE crm_products
        SET regex_pattern = #{quote(attrs[:regex])},
            sql_pattern   = #{quote(attrs[:sql])},
            updated_at    = NOW()
        WHERE key = #{quote(key)}
          AND regex_pattern IS NULL
      SQL
    end
  end

  def down
    PATTERNS.each_key do |key|
      execute <<~SQL
        UPDATE crm_products
        SET regex_pattern = NULL,
            sql_pattern   = NULL,
            updated_at    = NOW()
        WHERE key = #{quote(key)}
      SQL
    end
  end
end
