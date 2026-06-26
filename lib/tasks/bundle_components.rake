# frozen_string_literal: true

# Epic C Phase 3B — Bundle SKU component analysis tasks.
# All tasks in this file are READ-ONLY unless explicitly noted.

namespace :bundle_components do
  # ─────────────────────────────────────────────────────────────────────────
  # rails bundle_components:dry_run
  #
  # Scans confirmed product_name_mappings for bundle SKUs related to turmeric
  # and metabolism, parses each into component products, and reports what
  # component rows WOULD be inserted — without actually writing anything.
  #
  # Scope: raw_names that contain "薑黃" (turmeric) OR "代謝" (metabolism-family)
  # AND parse into 2+ distinct CrmProducts.
  # ─────────────────────────────────────────────────────────────────────────
  desc "DRY RUN: parse turmeric/metabolism bundle SKUs and show proposed components (no DB writes)"
  task dry_run: :environment do
    banner = ->(text) do
      bar = "─" * [text.length + 4, 60].max
      "\n#{bar}\n  #{text}\n#{bar}"
    end

    format_entry = ->(idx, mapping, parsed) do
      primary = mapping.crm_product&.key || "(none)"
      lines   = []
      lines << "  [#{idx}] #{mapping.raw_name.inspect}"
      lines << "       occurrence_count : #{mapping.occurrence_count}"
      lines << "       primary product  : #{primary}"
      lines << "       mapping_id       : #{mapping.id}"
      lines << "       existing comps   : #{mapping.components.size}"
      lines << "       parsed components:"
      if parsed.components.empty?
        lines << "         (none)"
      else
        parsed.components.each do |c|
          lines << "         #{c[:product_key].ljust(22)} qty=#{c[:quantity]}"
        end
      end
      lines << "       confidence       : #{parsed.confidence}"
      parsed.warnings.each { |w| lines << "       WARN: #{w}" }
      lines << ""
      lines.join("\n")
    end

    puts banner.call("Bundle Component Dry Run — Phase 3B")
    puts "Scope : confirmed product_name_mappings containing 薑黃 or 代謝"
    puts "Action: READ ONLY — zero rows written\n\n"

    # ── Step 1: Candidate filtering ──────────────────────────────────────
    turmeric_metabolism_kws = %w[薑黃 代謝錠 代謝定 代謝錠錠 代謝]

    all_confirmed = ProductNameMapping
                      .confirmed
                      .includes(:crm_product, :components)
                      .order(:raw_name)
                      .to_a

    candidates = all_confirmed.select do |m|
      turmeric_metabolism_kws.any? { |kw| m.raw_name.include?(kw) }
    end

    puts "Confirmed mappings total         : #{all_confirmed.size}"
    puts "Candidates (薑黃/代謝 related)   : #{candidates.size}\n\n"

    # ── Step 2: Parse all candidates ─────────────────────────────────────
    results = candidates.map do |mapping|
      parsed = BundleComponentParser.call(mapping.raw_name)
      { mapping: mapping, parsed: parsed }
    end

    high   = results.select { |r| r[:parsed].confidence == "high" }
    medium = results.select { |r| r[:parsed].confidence == "medium" }
    low    = results.select { |r| r[:parsed].confidence == "low" }

    puts "Confidence breakdown:"
    puts "  high   (2+ components)                   : #{high.size}"
    puts "  medium (1 component, suspected bundle)   : #{medium.size}"
    puts "  low    (0 parseable keywords)            : #{low.size}"
    puts

    # ── Step 3: Which bundles are NEW (no existing components) ───────────
    actionable = high.reject { |r| r[:mapping].components.any? }
    already    = high.select { |r| r[:mapping].components.any? }

    puts "Of #{high.size} high-confidence bundles:"
    puts "  #{actionable.size} have NO existing components → would INSERT rows"
    puts "  #{already.size}  already have components → would skip"
    puts

    # ── Step 4: Proposed insert summary ──────────────────────────────────
    total_rows = actionable.sum { |r| r[:parsed].components.size }
    puts "Total component rows to insert (proposed) : #{total_rows}"
    puts "Distinct raw_names to process             : #{actionable.size}"
    puts

    # ── Step 5: Detailed listing ──────────────────────────────────────────
    puts banner.call("Detailed Parse Results (high confidence, sorted by occurrence_count DESC)")
    puts

    all_warnings = []

    actionable.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
      m      = r[:mapping]
      parsed = r[:parsed]
      puts format_entry.call(i + 1, m, parsed)
      all_warnings.concat(parsed.warnings.map { |w| "[#{m.raw_name}] #{w}" })
    end

    # ── Step 6: Medium-confidence ─────────────────────────────────────────
    unless medium.empty?
      puts banner.call("Medium Confidence (suspected bundles — 1 component parsed)")
      puts "These may need manual inspection or ALIAS_MAP expansion.\n\n"
      medium.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
        m      = r[:mapping]
        parsed = r[:parsed]
        puts format_entry.call(i + 1, m, parsed)
        all_warnings.concat(parsed.warnings.map { |w| "[#{m.raw_name}] #{w}" })
      end
    end

    # ── Step 7: Low-confidence ────────────────────────────────────────────
    unless low.empty?
      puts banner.call("Low Confidence (0 components parsed — possible ALIAS_MAP gaps)")
      low.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
        m = r[:mapping]
        puts "  [#{i + 1}] #{m.raw_name.inspect}  cnt=#{m.occurrence_count}  primary=#{m.crm_product&.key}"
      end
      puts
    end

    # ── Step 8: Warning summary ───────────────────────────────────────────
    unless all_warnings.empty?
      puts banner.call("Warnings (#{all_warnings.size} total)")
      all_warnings.each { |w| puts "  WARN  #{w}" }
      puts
    end

    # ── Step 9: Sanity checks ─────────────────────────────────────────────
    puts banner.call("Sanity Check — Expected Parse Results")
    sanity_cases = {
      "代謝錠1薑黃1"           => { "metabolism" => 1, "turmeric" => 1 },
      "薑黃1全能1"             => { "omnipotent" => 1, "turmeric" => 1 },
      "代謝錠2薑黃2"           => { "metabolism" => 2, "turmeric" => 2 },
      "代謝錠1全能1薑黃1"      => { "metabolism" => 1, "omnipotent" => 1, "turmeric" => 1 },
      "薑黃4全能3"             => { "omnipotent" => 3, "turmeric" => 4 },
      "代謝錠1薑黃1全能1美白1" => { "metabolism" => 1, "omnipotent" => 1, "turmeric" => 1, "whitening" => 1 },
      "代謝錠6薑黃6"           => { "metabolism" => 6, "turmeric" => 6 },
    }

    all_pass = true
    puts
    sanity_cases.each do |raw, expected_map|
      parsed  = BundleComponentParser.call(raw)
      got_map = parsed.components.each_with_object({}) { |c, h| h[c[:product_key]] = c[:quantity] }
      pass    = got_map == expected_map
      all_pass = false unless pass
      puts "  #{pass ? "PASS" : "FAIL"}  #{raw.inspect}"
      unless pass
        puts "        expected : #{expected_map.inspect}"
        puts "        got      : #{got_map.inspect}"
      end
    end

    puts
    puts all_pass ? "All sanity checks PASSED." : "SANITY CHECK FAILURES — review ALIAS_MAP"

    # ── Step 10: orders_for count preview ────────────────────────────────
    puts banner.call("orders_for Count Preview (current vs projected)")
    puts "Note: projected counts include bundle component hits — actual change after write.\n\n"

    [%w[turmeric 薑黃], %w[metabolism 代謝]].each do |key, _label|
      current = ProductNameResolver.orders_for(key).count
      puts "  #{key.ljust(12)} current orders_for: #{current}"
    end
    puts

    # ── Final summary ─────────────────────────────────────────────────────
    puts banner.call("Summary")
    puts "  Confirmed mappings scanned     : #{all_confirmed.size}"
    puts "  Candidates (薑黃/代謝)         : #{candidates.size}"
    puts "  HIGH confidence bundles        : #{high.size}"
    puts "  MEDIUM confidence (suspected)  : #{medium.size}"
    puts "  LOW confidence                 : #{low.size}"
    puts "  Rows to insert (proposed)      : #{total_rows} across #{actionable.size} raw_names"
    puts "  Warnings                       : #{all_warnings.size}"
    puts "  DB writes                      : 0  ← DRY RUN ONLY"
    puts
    puts "Next step (Phase 3C): review results, then run:"
    puts "  rails bundle_components:write"
    puts
  end
end
