# frozen_string_literal: true

# Epic D5 / E1 — one-shot bootstrap for a fresh production environment.
#
# Phase 1: Seeds all 13 CrmProducts (with initial regex_pattern), then seeds
#           their CrmProductAliases (idempotent — find_or_create_by).
#
# Phase 1b: Runs ProductAliasRegexGeneratorService to regenerate regex_pattern
#            from the seeded aliases (longer aliases sorted first, Regexp.escape'd).
#            This overwrites the hardcoded initial regex with the alias-canonical form.
#
# Phase 2: Delegates to ProductCandidateGeneratorService to scan raw SKU sources
#           (ShoplineOrder + LivestreamProduct) and build product_name_mappings
#           candidates with auto-suggestions.
#
# Idempotent rules (per product key):
#   - key absent              → CREATE product + aliases; Phase 1b updates regex
#   - key present, regex nil  → UPDATE regex from hardcoded constant + seed aliases
#   - key present, regex set  → SKIP product row; still seed missing aliases
#
# Never:
#   - auto-confirms product_name_mappings
#   - writes ProductMappingComponents (that is bundle_components:write)
#   - overwrites aliases that a human has set to inactive
#
# Usage (called from product_registry:bootstrap rake task):
#   ProductRegistryBootstrapService.call
#   ProductRegistryBootstrapService.call(dry_run: true)
class ProductRegistryBootstrapService
  # ── Alias registry (source of truth for all known product name variants) ──
  #
  # Aliases drive regex generation via ProductAliasRegexGeneratorService.
  # Add / edit here; run product_aliases:generate_regex to propagate.
  #
  # Typo variants (代謝定, 代謝錠錠, 榖胱甘肽, 益生箘) are real spellings seen
  # in imported order data — first catalogued in BundleComponentParser's
  # ALIAS_MAP (Epic C), promoted into the alias registry in Epic E3-2.1 so
  # the generated regex_pattern covers them too.
  ALIASES_BY_KEY = {
    "omnipotent"         => %w[全能 B群 B群全能 全能膠囊],
    "metabolism"         => %w[代謝 代謝錠 代謝定 代謝錠錠],
    "glutathione"        => %w[穀胱甘肽 榖胱甘肽],
    "collagen"           => %w[膠原 膠原蛋白],
    "turmeric"           => %w[薑黃],
    "probiotic"          => %w[益生菌 益生箘],
    "whitening"          => %w[美白],
    "fish_oil"           => %w[魚油],
    "cleanse_powder"     => %w[清纖 清纖粉],
    "astaxanthin"        => %w[蝦紅素],
    "intimate_powder"    => %w[私密 私密粉],
    # 面 (bare) is real store shorthand — 面1/面3/面6/面10 exist as confirmed
    # mask mappings. The dev regex had been hand-widened to 面(?:膜)?(\d+) to
    # cover them; the alias registry needs 面 explicitly or regeneration
    # regresses those four mappings (found in E3-2.1).
    "mask"               => %w[面膜 面],
    "vitamin_dk_calcium" => %w[維DK鈣 DK鈣],
  }.freeze

  # ── Product definitions (key / label / sql / source) ─────────────────────
  #
  # regex is kept here only as the *initial* value when creating a new CrmProduct
  # row.  After aliases are seeded, Phase 1b overwrites regex_pattern with the
  # alias-generated canonical form.
  CORE_PRODUCTS = (
    JourneyProducts::PRODUCTS.values.map { |p|
      { key: p[:key], label: p[:label], regex: p[:regex], sql: p[:sql],
        source: "journey_products_seed" }
    } + [
      { key: "probiotic", label: "益生菌", regex: /益生菌(\d+)/,
        sql: "product_name LIKE '%益生菌%'", source: "journey_products_seed" }
    ]
  ).freeze

  EXTENDED_PRODUCTS = [
    { key: "whitening",          label: "美白",   regex: /美白(\d+)/,
      sql: "product_name LIKE '%美白%'",                                            source: "bootstrap_seed" },
    { key: "fish_oil",           label: "魚油",   regex: /魚油(\d+)/,
      sql: "product_name LIKE '%魚油%'",                                            source: "bootstrap_seed" },
    { key: "cleanse_powder",     label: "清纖粉", regex: /清纖粉(\d+)/,
      sql: "product_name LIKE '%清纖粉%'",                                          source: "bootstrap_seed" },
    { key: "astaxanthin",        label: "蝦紅素", regex: /蝦紅素(\d+)/,
      sql: "product_name LIKE '%蝦紅素%'",                                          source: "bootstrap_seed" },
    { key: "intimate_powder",    label: "私密粉", regex: /私密粉?(\d+)/,
      sql: "product_name LIKE '%私密%'",                                            source: "bootstrap_seed" },
    { key: "mask",               label: "面膜",   regex: /面膜(\d+)/,
      sql: "product_name LIKE '%面膜%'",                                            source: "bootstrap_seed" },
    { key: "vitamin_dk_calcium", label: "維DK鈣", regex: /維*DK鈣(\d+)/,
      sql: "product_name LIKE '%DK鈣%' OR product_name LIKE '%維DK鈣%'",           source: "bootstrap_seed" },
  ].freeze

  ALL_PRODUCTS = (CORE_PRODUCTS + EXTENDED_PRODUCTS).freeze

  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
    @log     = []
    @summary = { created: 0, patterns_backfilled: 0, skipped: 0,
                 aliases_created: 0, aliases_skipped: 0, regex_updated: 0 }
  end

  def call
    phase1_seed_products!
    phase1b_generate_regex!
    phase2_build_mapping_candidates! unless @dry_run
    { summary: @summary, log: @log }
  end

  private

  # ── Phase 1: seed CrmProducts + CrmProductAliases ─────────────────────────

  def phase1_seed_products!
    ALL_PRODUCTS.each do |p|
      existing = CrmProduct.find_by(key: p[:key])

      if existing.nil?
        @summary[:created] += 1
        log(:create, p[:key], "#{p[:label]} (new product)")
        unless @dry_run
          product = CrmProduct.create!(
            key: p[:key], label: p[:label], status: "confirmed",
            include_in_analysis: true, source: p[:source],
            regex_pattern: p[:regex].source, sql_pattern: p[:sql]
          )
          seed_aliases!(product, ALIASES_BY_KEY.fetch(p[:key], []))
        end

      elsif existing.regex_pattern.blank?
        @summary[:patterns_backfilled] += 1
        log(:backfill, p[:key], "regex/sql was NULL → backfilling")
        unless @dry_run
          existing.update!(regex_pattern: p[:regex].source, sql_pattern: p[:sql])
          seed_aliases!(existing, ALIASES_BY_KEY.fetch(p[:key], []))
        end

      else
        @summary[:skipped] += 1
        log(:skip, p[:key], "product complete — seeding missing aliases only")
        seed_aliases!(existing, ALIASES_BY_KEY.fetch(p[:key], [])) unless @dry_run
      end

      # In dry_run, preview aliases and planned regex without writing.
      if @dry_run
        aliases      = ALIASES_BY_KEY.fetch(p[:key], [])
        planned_regex = ProductAliasRegexGeneratorService.generate_pattern(aliases)
        log(:alias_preview, p[:key], "aliases=#{aliases.inspect} → regex=#{planned_regex.inspect}")
      end
    end
  end

  def seed_aliases!(product, alias_names)
    alias_names.each do |name|
      created = CrmProductAlias.find_or_create_by!(crm_product: product, alias_name: name) do |a|
        a.status           = "active"
        a.source           = "seed"
        a.normalized_alias = name.strip
      end
      if created.previously_new_record?
        @summary[:aliases_created] += 1
      else
        @summary[:aliases_skipped] += 1
      end
    end
  end

  # ── Phase 1b: regenerate regex from aliases ────────────────────────────────

  def phase1b_generate_regex!
    return if @dry_run  # already previewed inline in phase1

    result = ProductAliasRegexGeneratorService.call(dry_run: false)
    @summary[:regex_updated] = result[:summary][:updated]
    result[:log].each { |entry| log(entry[:action], entry[:key], entry[:detail]) }
  end

  # ── Phase 2: delegate to ProductCandidateGeneratorService ──────────────────

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
