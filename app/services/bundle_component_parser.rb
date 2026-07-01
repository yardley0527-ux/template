# frozen_string_literal: true

# Parses a bundle SKU raw_name into its constituent CrmProduct components.
#
# A bundle SKU is a single product name that actually contains multiple
# distinct products, e.g. "代謝錠1薑黃1" = 1 metabolism + 1 turmeric.
#
# Usage:
#   result = BundleComponentParser.call("代謝錠1薑黃1")
#   result.components  # => [{product_key: "metabolism", quantity: 1},
#                      #      {product_key: "turmeric",  quantity: 1}]
#   result.warnings    # => []
#   result.confidence  # => "high"
#
# Phase 3B: dry-run only — this class never writes to product_mapping_components.
# Actual writes happen in Phase 3C after human review of the dry-run output.
class BundleComponentParser
  Result = Struct.new(:components, :warnings, :confidence, keyword_init: true)

  # Keyword → CrmProduct.key alias map.
  # Rules:
  #   1. Longer keys must appear before shorter sub-strings (代謝錠錠 before 代謝錠 before 代謝)
  #      so that gsub eliminates them before shorter aliases can double-match.
  #   2. Typo variants are listed alongside canonical spellings.
  #   3. "美白" maps to "whitening" per the product registry (not "glutathione").
  ALIAS_MAP = {
    # 5-char — longest first
    "穀胱甘肽"   => "glutathione",
    "榖胱甘肽"   => "glutathione",    # 榖 vs 穀 variant
    "膠原蛋白"   => "collagen",
    "代謝錠錠"   => "metabolism",     # double-錠 typo
    "維DK鈣"    => "vitamin_dk_calcium",
    # 3-char
    "蝦紅素"    => "astaxanthin",
    "益生菌"    => "probiotic",
    "益生箘"    => "probiotic",       # 箘 vs 菌 typo
    "清纖粉"    => "cleanse_powder",
    "私密粉"    => "intimate_powder",
    "代謝錠"    => "metabolism",
    "代謝定"    => "metabolism",      # 定 vs 錠 typo
    "薑黃"      => "turmeric",
    "全能"      => "omnipotent",
    "膠原"      => "collagen",
    "魚油"      => "fish_oil",
    "代謝"      => "metabolism",      # short alias — after 代謝錠
    "美白"      => "whitening",
    "面膜"      => "mask",
    "清纖"      => "cleanse_powder",
    "私密"      => "intimate_powder",
    "DK鈣"     => "vitamin_dk_calcium",
    "B群"       => "omnipotent",
  }.freeze

  # Aliases sorted by key length descending (longest first), computed once.
  SORTED_ALIASES = ALIAS_MAP.keys.sort_by { |k| -k.length }.freeze

  # Returns a Result with components, warnings, and confidence.
  def self.call(raw_name)
    new.parse(raw_name.to_s.strip)
  end

  def parse(raw_name)
    found    = {}   # product_key => quantity
    warnings = []
    working  = raw_name.dup

    SORTED_ALIASES.each do |keyword|
      next unless working.include?(keyword)

      product_key = ALIAS_MAP[keyword]

      unless CrmProduct.exists?(key: product_key)
        warnings << "unknown_crm_product_key:#{product_key} (alias:#{keyword})"
        working = working.gsub(keyword, "")
        next
      end

      # Match keyword + optional whitespace + optional integer.
      # We intentionally stop at the first non-whitespace/non-digit so that
      # patterns like "全能4+1" capture 4, not "+1".
      m = working.match(Regexp.new(Regexp.escape(keyword) + '\s*(\d+)?'))
      if m
        qty = m[1].to_i
        qty = 1 if qty.zero?
        # If the same product appears via a shorter alias, take the larger qty
        found[product_key] = [found.fetch(product_key, 0), qty].max
      end

      # Remove the keyword AND the trailing digits from working string so:
      # (a) shorter aliases cannot re-match within this keyword (e.g. 代謝 inside 代謝錠)
      # (b) consumed digits do not bleed into the next keyword's quantity match
      #     (e.g. "薑黃1全能1" → after removing "薑黃1" we get "全能1", not "全能11")
      working = working.gsub(Regexp.new(Regexp.escape(keyword) + '\s*\d*'), "")
    end

    components = found.map { |key, qty| { product_key: key, quantity: qty } }
                      .sort_by { |c| c[:product_key] }

    confidence = if components.size >= 2
      "high"
    elsif components.size == 1 && bundle_suspected?(raw_name)
      warnings << "only_one_component_detected_but_name_looks_like_bundle:#{raw_name}"
      "medium"
    else
      "low"
    end

    Result.new(components: components, warnings: warnings, confidence: confidence)
  end

  private

  # Heuristic: multiple distinct digit groups suggest a bundle
  # (e.g. "全能10送2" has "10" and "2" → suspected bundle)
  def bundle_suspected?(raw_name)
    raw_name.scan(/\d+/).size >= 2
  end
end
