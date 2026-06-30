# frozen_string_literal: true

# Epic D5 — one-shot bootstrap for a fresh production environment.
#
# Seeds all 13 known CrmProducts with regex_pattern and sql_pattern, then
# delegates to ProductCandidateGeneratorService to scan raw SKU sources and
# build product_name_mappings candidates with auto-suggestions.
#
# Idempotent rules (per product key):
#   - key absent           → CREATE (status=confirmed, include_in_analysis=true)
#   - key present, regex nil  → UPDATE regex_pattern + sql_pattern only
#   - key present, regex set  → SKIP (preserves any human edits to label/notes)
#
# Never:
#   - auto-confirms product_name_mappings
#   - writes ProductMappingComponents (that is bundle_components:write)
#   - touches rows a reviewer has already acted on
#
# Usage (called from product_registry:bootstrap rake task):
#   ProductRegistryBootstrapService.call
#   ProductRegistryBootstrapService.call(dry_run: true)

class ProductRegistryBootstrapService
  # 6 journey/core products — identical definitions to ProductCandidateGeneratorService::KNOWN_PRODUCTS
  # so both tasks stay in sync and idempotent re-runs are safe.
  CORE_PRODUCTS = (
    JourneyProducts::PRODUCTS.values.map { |p|
      { key: p[:key], label: p[:label], regex: p[:regex], sql: p[:sql], source: "journey_products_seed" }
    } + [
      { key: "probiotic", label: "益生菌", regex: /益生菌(\d+)/, sql: "product_name LIKE '%益生菌%'", source: "journey_products_seed" }
    ]
  ).freeze

  # 7 products identified during Epic B2 Phase 2 Product Dictionary Review.
  # Patterns are the authoritative source — identical to migration 20260627000008.
  EXTENDED_PRODUCTS = [
    { key: "whitening",          label: "美白",   regex: /美白(\d+)/,          sql: "product_name LIKE '%美白%'",                                             source: "bootstrap_seed" },
    { key: "fish_oil",           label: "魚油",   regex: /魚油(\d+)/,          sql: "product_name LIKE '%魚油%'",                                             source: "bootstrap_seed" },
    { key: "cleanse_powder",     label: "清纖粉", regex: /清纖粉(\d+)/,        sql: "product_name LIKE '%清纖粉%'",                                           source: "bootstrap_seed" },
    { key: "astaxanthin",        label: "蝦紅素", regex: /蝦紅素(\d+)/,        sql: "product_name LIKE '%蝦紅素%'",                                           source: "bootstrap_seed" },
    { key: "intimate_powder",    label: "私密粉", regex: /私密粉?(\d+)/,       sql: "product_name LIKE '%私密%'",                                             source: "bootstrap_seed" },
    { key: "mask",               label: "面膜",   regex: /面(?:膜)?(\d+)/,     sql: "product_name LIKE '%面膜%'",                                             source: "bootstrap_seed" },
    { key: "vitamin_dk_calcium", label: "維DK鈣", regex: /維*DK鈣(\d+)/,       sql: "product_name LIKE '%DK鈣%' OR product_name LIKE '%維DK鈣%'",            source: "bootstrap_seed" },
  ].freeze

  ALL_PRODUCTS = (CORE_PRODUCTS + EXTENDED_PRODUCTS).freeze

  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
    @log     = []
    @summary = { created: 0, patterns_backfilled: 0, skipped: 0 }
  end

  def call
    phase1_seed_products!
    phase2_build_mapping_candidates! unless @dry_run
    { summary: @summary, log: @log }
  end

  private

  # ── Phase 1: seed / backfill all 13 CrmProducts ────────────────────────
  def phase1_seed_products!
    ALL_PRODUCTS.each do |p|
      existing = CrmProduct.find_by(key: p[:key])

      if existing.nil?
        @summary[:created] += 1
        log(:create, p[:key], p[:label])
        next if @dry_run

        CrmProduct.create!(
          key:                 p[:key],
          label:               p[:label],
          status:              "confirmed",
          include_in_analysis: true,
          source:              p[:source],
          regex_pattern:       p[:regex].source,
          sql_pattern:         p[:sql]
        )

      elsif existing.regex_pattern.blank?
        @summary[:patterns_backfilled] += 1
        log(:backfill, p[:key], "regex/sql was NULL → backfilling")
        next if @dry_run

        existing.update!(
          regex_pattern: p[:regex].source,
          sql_pattern:   p[:sql]
        )

      else
        @summary[:skipped] += 1
        log(:skip, p[:key], "already complete")
      end
    end
  end

  # ── Phase 2: delegate to ProductCandidateGeneratorService ───────────────
  # Scans ShoplineOrder + LivestreamProduct SKUs, upserts product_name_mappings
  # with occurrence_count, and writes auto-suggestions for pending rows.
  # Only called when not in dry_run — the generator handles its own idempotency.
  def phase2_build_mapping_candidates!
    mapping_summary = ProductCandidateGeneratorService.call(dry_run: false)
    @summary[:mappings_created]    = mapping_summary[:shopline_order_created].to_i +
                                     mapping_summary[:livestream_product_created].to_i
    @summary[:mappings_updated]    = mapping_summary[:shopline_order_updated].to_i +
                                     mapping_summary[:livestream_product_updated].to_i
    @summary[:suggestions_written] = mapping_summary[:suggestions_written].to_i
  end

  def log(action, key, detail)
    @log << { action: action, key: key, detail: detail }
  end
end
