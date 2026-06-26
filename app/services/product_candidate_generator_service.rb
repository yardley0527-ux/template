# frozen_string_literal: true

# Epic B2-2A — scans raw product-name sources (ShoplineOrder, LivestreamProduct)
# and maintains `product_name_mappings` as a queryable candidate list for the
# Product Registry Review UI (Epic B2-0B). It never decides anything on a
# human's behalf — `crm_product_id`/`mapping_status` are only ever written by
# a reviewer; this service only writes `occurrence_count` and the
# `suggested_*` columns, and only for rows still in `pending` status.
class ProductCandidateGeneratorService
  # Products already proven in production by the 5 existing analysis
  # controllers / JourneyProducts — seeded as `confirmed` so reviewers don't
  # have to re-approve facts that are already live. `collagen` has no
  # dedicated analysis controller but is already a recognized product_key
  # (JourneyProducts::PRODUCTS, crm_rollup:refresh_all iterates it) so it is
  # seeded too. `probiotic` has a controller but was never added to
  # JourneyProducts::PRODUCTS (a gap found during the Epic B1 audit) — added
  # here explicitly so the registry doesn't inherit that omission.
  KNOWN_PRODUCTS = JourneyProducts::PRODUCTS.values.map { |p|
    { key: p[:key], label: p[:label], regex: p[:regex], sql: p[:sql] }
  } + [
    { key: "probiotic", label: "益生菌", regex: /益生菌(\d+)/, sql: "product_name LIKE '%益生菌%'" }
  ]

  HIGH_CONFIDENCE_SIMILARITY   = 0.6
  MEDIUM_CONFIDENCE_SIMILARITY = 0.3

  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
    @summary = Hash.new(0)
  end

  def call
    ActiveRecord::Base.transaction do
      seed_known_products!
      scan_and_upsert_mappings!
      generate_suggestions!
      raise ActiveRecord::Rollback if @dry_run
    end
    @summary
  end

  private

  # ── Step 1: seed crm_products ──────────────────────────────────────
  # Idempotent — only creates missing keys, never touches an existing row
  # (a human may have since edited label/status/notes on a seeded row).

  def seed_known_products!
    KNOWN_PRODUCTS.each do |p|
      next if CrmProduct.exists?(key: p[:key])

      @summary[:products_seeded] += 1
      next if @dry_run

      CrmProduct.create!(
        key: p[:key],
        label: p[:label],
        status: "confirmed",
        include_in_analysis: true,
        source: "journey_products_seed",
        regex_pattern: p[:regex]&.source,
        sql_pattern: p[:sql]
      )
    end
  end

  # ── Step 2: scan raw sources, upsert mapping rows ───────────────────
  # occurrence_count is SET to the true current count from the source data
  # (not incremented), so reruns stay accurate regardless of how many times
  # the task has executed. crm_product_id / mapping_status / suggested_* are
  # NEVER touched here for rows a reviewer has already acted on.

  def scan_and_upsert_mappings!
    upsert_counts("shopline_order", shopline_order_counts)
    upsert_counts("livestream_product", livestream_product_counts)
  end

  def shopline_order_counts
    ShoplineOrder.where.not(product_name: [nil, ""])
      .group(:product_name).count
  end

  def livestream_product_counts
    LivestreamProduct.where.not(name: [nil, ""])
      .group(:name).count
  end

  def upsert_counts(source, counts_by_name)
    counts_by_name.each do |raw_name, count|
      raw_name = raw_name.to_s.strip
      next if raw_name.blank?

      existing = ProductNameMapping.find_by(raw_name: raw_name, source: source)

      if existing
        @summary["#{source}_updated".to_sym] += 1
        existing.update!(occurrence_count: count) unless @dry_run
      else
        @summary["#{source}_created".to_sym] += 1
        next if @dry_run

        ProductNameMapping.create!(
          raw_name: raw_name,
          source: source,
          occurrence_count: count,
          mapping_status: "pending"
        )
      end
    end
  end

  # ── Step 3: suggestions for still-pending rows only ─────────────────

  def generate_suggestions!
    confirmed_products = CrmProduct.confirmed.to_a
    return if confirmed_products.empty?

    ProductNameMapping.pending.find_each do |mapping|
      suggestion = suggest_for(mapping.raw_name, confirmed_products)
      next unless suggestion

      @summary[:suggestions_written] += 1
      next if @dry_run

      mapping.update!(
        suggested_crm_product_id: suggestion[:product].id,
        suggested_confidence: suggestion[:confidence]
      )
    end
  end

  def suggest_for(raw_name, confirmed_products)
    confirmed_products.each do |product|
      next unless product.regex_pattern.present?

      return { product: product, confidence: "High" } if raw_name.match?(Regexp.new(product.regex_pattern))
    end

    # The regex's literal prefix (e.g. "膠原" out of "膠原(\d+)") is often a
    # cleaner bare ingredient keyword than `label`, which may carry marketing
    # suffixes (e.g. label "膠原飲" vs SKU text "膠原（1盒）" — no digit
    # immediately follows "膠原" there, so the regex itself can't match, but
    # the keyword still substring-matches).
    confirmed_products.each do |product|
      next unless product.regex_pattern.present?

      core = product.regex_pattern.gsub(/\(.*?\)|\?/, "").strip
      next if core.length < 2

      return { product: product, confidence: "High" } if raw_name.include?(core)
    end

    confirmed_products.each do |product|
      # Labels can be compound (e.g. "B群／全能") and not appear verbatim in
      # raw_name, so match on any individual segment rather than the whole
      # label string.
      segments = product.label.split(/[\／\/、,，]/).map(&:strip).reject { |s| s.length < 2 }
      return { product: product, confidence: "High" } if segments.any? { |seg| raw_name.include?(seg) }
    end

    best = best_trigram_match(raw_name, confirmed_products)
    return nil unless best

    confidence = if best[:similarity] >= HIGH_CONFIDENCE_SIMILARITY
      "High"
    elsif best[:similarity] >= MEDIUM_CONFIDENCE_SIMILARITY
      "Medium"
    else
      "Low"
    end

    { product: best[:product], confidence: confidence }
  end

  def best_trigram_match(raw_name, confirmed_products)
    conn = ActiveRecord::Base.connection
    rows = confirmed_products.map do |product|
      sim = conn.select_value(
        "SELECT similarity(#{conn.quote(raw_name)}, #{conn.quote(product.label)})"
      ).to_f
      { product: product, similarity: sim }
    end

    best = rows.max_by { |r| r[:similarity] }
    return nil if best.nil? || best[:similarity] <= 0

    best
  end
end
