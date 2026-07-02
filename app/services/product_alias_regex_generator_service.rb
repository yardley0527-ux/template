# frozen_string_literal: true

# Epic E1 — Generates crm_products.regex_pattern from active CrmProductAliases.
#
# Algorithm:
#   1. For each CrmProduct, collect its active aliases.
#   2. Sort aliases longest-first (prevents a short alias from consuming the
#      beginning of a longer alias during alternation matching).
#   3. Regexp.escape each alias.
#   4. Build: single alias → "alias(\d+)"
#              multiple    → "(?:longest|...|shortest)(\d+)"
#   5. Compare generated pattern to stored regex_pattern:
#      - Changed  → update crm_products.regex_pattern (unless dry_run)
#      - Unchanged → skip
#      - No active aliases → skip (never overwrites with empty pattern)
#
# Safety:
#   - Never touches product_name_mappings or product_mapping_components.
#   - Never auto-confirms mappings.
#   - dry_run: true previews all changes without any DB writes.
#
# Usage:
#   ProductAliasRegexGeneratorService.call
#   ProductAliasRegexGeneratorService.call(dry_run: true)
class ProductAliasRegexGeneratorService
  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
    @log     = []
    @summary = { updated: 0, skipped_unchanged: 0, skipped_no_aliases: 0 }
  end

  def call
    CrmProduct.includes(:crm_product_aliases).find_each do |product|
      active_aliases = product.crm_product_aliases.select { |a| a.status == "active" }

      if active_aliases.empty?
        @summary[:skipped_no_aliases] += 1
        log(:skip_no_aliases, product.key, "no active aliases — regex_pattern preserved as-is")
        next
      end

      new_pattern = generate_pattern(active_aliases.map(&:alias_name))

      if product.regex_pattern == new_pattern
        @summary[:skipped_unchanged] += 1
        log(:skip_unchanged, product.key, new_pattern)
        next
      end

      @summary[:updated] += 1
      log(:update, product.key, "#{product.regex_pattern.inspect} → #{new_pattern.inspect}")

      product.update!(regex_pattern: new_pattern) unless @dry_run
    end

    { summary: @summary, log: @log }
  end

  # Public so bootstrap service can call it for dry_run preview without DB reads.
  def self.generate_pattern(alias_names)
    new.send(:generate_pattern, alias_names)
  end

  private

  # Sort longest alias first to ensure longer strings are tried before shorter
  # prefix-of-longer strings in the alternation (e.g. "膠原蛋白" before "膠原").
  def generate_pattern(alias_names)
    sorted  = alias_names.map(&:strip).uniq.sort_by { |a| -a.length }
    escaped = sorted.map { |a| Regexp.escape(a) }

    alternation = escaped.size == 1 ? escaped.first : "(?:#{escaped.join('|')})"
    "#{alternation}(\\d+)"
  end

  def log(action, key, detail)
    @log << { action: action, key: key, detail: detail }
  end
end
