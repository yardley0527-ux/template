# frozen_string_literal: true

# Epic C Phase 3B/3C — Bundle SKU component tasks.
#
# Workflow:
#   1.  rails bundle_components:dry_run       — inspect what WOULD be written
#   2.  rails bundle_components:export_review — export CSV for human review
#   3.  rails bundle_components:write         — write after human confirms YES
#                                              (or FORCE=true for automation)

namespace :bundle_components do

  # ── Shared helpers ────────────────────────────────────────────────────────

  TURMERIC_METABOLISM_KWS = %w[薑黃 代謝錠 代謝定 代謝錠錠 代謝].freeze
  PARSER_VERSION          = "v1".freeze

  # Returns all HIGH-confidence bundle candidates as an array of hashes:
  #   [{ mapping:, parsed:, turmeric_delta_orders:, metabolism_delta_orders: }, ...]
  # Always scoped to confirmed mappings that contain 薑黃 or 代謝 AND parse to 2+ products.
  build_candidates = lambda do
    all_confirmed = ProductNameMapping
                      .confirmed
                      .includes(:crm_product, :components)
                      .order(:raw_name)
                      .to_a

    candidates = all_confirmed.select do |m|
      TURMERIC_METABOLISM_KWS.any? { |kw| m.raw_name.include?(kw) }
    end

    candidates.map do |mapping|
      parsed = BundleComponentParser.call(mapping.raw_name)
      { mapping: mapping, parsed: parsed }
    end.select { |r| r[:parsed].confidence == "high" }
  end

  # ────────────────────────────────────────────────────────────────────────
  # rails bundle_components:dry_run
  # ────────────────────────────────────────────────────────────────────────
  desc "DRY RUN: parse turmeric/metabolism bundle SKUs — no DB writes"
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
    puts "Scope : confirmed mappings containing 薑黃 or 代謝"
    puts "Action: READ ONLY — zero rows written\n\n"

    turmeric_metabolism_kws = TURMERIC_METABOLISM_KWS

    all_confirmed = ProductNameMapping.confirmed.includes(:crm_product, :components)
                                      .order(:raw_name).to_a
    candidates    = all_confirmed.select do |m|
      turmeric_metabolism_kws.any? { |kw| m.raw_name.include?(kw) }
    end

    puts "Confirmed mappings total         : #{all_confirmed.size}"
    puts "Candidates (薑黃/代謝 related)   : #{candidates.size}\n\n"

    results = candidates.map { |m| { mapping: m, parsed: BundleComponentParser.call(m.raw_name) } }

    high   = results.select { |r| r[:parsed].confidence == "high" }
    medium = results.select { |r| r[:parsed].confidence == "medium" }
    low    = results.select { |r| r[:parsed].confidence == "low" }

    puts "Confidence breakdown:"
    puts "  high   (2+ components)                   : #{high.size}"
    puts "  medium (1 component, suspected bundle)   : #{medium.size}"
    puts "  low    (0 parseable keywords)            : #{low.size}"
    puts

    actionable  = high.reject { |r| r[:mapping].components.any? }
    already     = high.select { |r| r[:mapping].components.any? }
    total_rows  = actionable.sum { |r| r[:parsed].components.size }
    all_warnings = []

    puts "Of #{high.size} high-confidence bundles:"
    puts "  #{actionable.size} have NO existing components → would INSERT rows"
    puts "  #{already.size}  already have components → would skip"
    puts "\nTotal component rows to insert (proposed) : #{total_rows}"
    puts "Distinct raw_names to process             : #{actionable.size}\n"

    puts banner.call("Detailed Parse Results (high confidence, by occurrence_count DESC)")
    puts

    actionable.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
      puts format_entry.call(i + 1, r[:mapping], r[:parsed])
      all_warnings.concat(r[:parsed].warnings.map { |w| "[#{r[:mapping].raw_name}] #{w}" })
    end

    unless medium.empty?
      puts banner.call("Medium Confidence (suspected bundles — 1 component)")
      medium.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
        puts format_entry.call(i + 1, r[:mapping], r[:parsed])
        all_warnings.concat(r[:parsed].warnings.map { |w| "[#{r[:mapping].raw_name}] #{w}" })
      end
    end

    unless low.empty?
      puts banner.call("Low Confidence (0 components — possible ALIAS_MAP gaps)")
      low.sort_by { |r| -r[:mapping].occurrence_count.to_i }.each_with_index do |r, i|
        m = r[:mapping]
        puts "  [#{i + 1}] #{m.raw_name.inspect}  cnt=#{m.occurrence_count}  primary=#{m.crm_product&.key}"
      end
      puts
    end

    unless all_warnings.empty?
      puts banner.call("Warnings")
      all_warnings.each { |w| puts "  WARN  #{w}" }
    end

    puts banner.call("Sanity Checks")
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
    sanity_cases.each do |raw, expected|
      parsed  = BundleComponentParser.call(raw)
      got     = parsed.components.each_with_object({}) { |c, h| h[c[:product_key]] = c[:quantity] }
      pass    = got == expected
      all_pass = false unless pass
      puts "  #{pass ? "PASS" : "FAIL"}  #{raw.inspect}"
      next if pass
      puts "        expected : #{expected.inspect}"
      puts "        got      : #{got.inspect}"
    end
    puts
    puts all_pass ? "All sanity checks PASSED." : "SANITY FAILURES — review ALIAS_MAP"

    puts banner.call("Summary")
    puts "  Confirmed mappings scanned     : #{all_confirmed.size}"
    puts "  Candidates (薑黃/代謝)         : #{candidates.size}"
    puts "  HIGH confidence bundles        : #{high.size}"
    puts "  MEDIUM confidence              : #{medium.size}"
    puts "  LOW confidence                 : #{low.size}"
    puts "  Rows to insert (proposed)      : #{total_rows} across #{actionable.size} raw_names"
    puts "  Warnings                       : #{all_warnings.size}"
    puts "  DB writes                      : 0  ← DRY RUN ONLY"
    puts
    puts "Next: rails bundle_components:export_review > tmp/bundle_review.csv"
  end

  # ────────────────────────────────────────────────────────────────────────
  # rails bundle_components:export_review
  # Outputs CSV to stdout; redirect to file:
  #   rails bundle_components:export_review > tmp/bundle_review.csv
  # ────────────────────────────────────────────────────────────────────────
  desc "Export HIGH-confidence bundle parse results to CSV for human review (stdout)"
  task export_review: :environment do
    require "csv"

    high_bundles = build_candidates.call

    rows = high_bundles.map do |r|
      mapping = r[:mapping]
      parsed  = r[:parsed]
      {
        raw_name:            mapping.raw_name,
        primary_product:     mapping.crm_product&.key.to_s,
        detected_components: parsed.components.map { |c| "#{c[:product_key]}:#{c[:quantity]}" }.join("|"),
        occurrence_count:    mapping.occurrence_count.to_i,
        confidence:          parsed.confidence.upcase,
        mapping_status:      mapping.mapping_status,
        component_count:     parsed.components.size,
        parser_version:      PARSER_VERSION,
        already_has_comps:   mapping.components.any? ? "yes" : "no",
        warning:             parsed.warnings.join("; "),
      }
    end

    # Sort: component_count DESC, occurrence_count DESC
    rows.sort_by! { |r| [-r[:component_count], -r[:occurrence_count]] }

    csv_out = CSV.generate(force_quotes: false) do |csv|
      csv << rows.first.keys.map(&:to_s)
      rows.each { |r| csv << r.values }
    end

    print csv_out

    warn "\n[export_review] #{rows.size} rows exported (HIGH confidence bundles only)"
    warn "[export_review] Redirect to file: rails bundle_components:export_review > tmp/bundle_review.csv"
  end

  # ────────────────────────────────────────────────────────────────────────
  # rails bundle_components:write
  # Writes ProductMappingComponent records after human approval.
  # Set FORCE=true to skip interactive confirmation (for automation).
  # ────────────────────────────────────────────────────────────────────────
  desc "Write bundle components to DB (requires YES confirmation or FORCE=true)"
  task write: :environment do
    separator = "=" * 70

    puts separator
    puts " Bundle Component Write — Phase 3C"
    puts separator

    # ── 1. Collect bundles ─────────────────────────────────────────────
    high_bundles = build_candidates.call
    actionable   = high_bundles.reject { |r| r[:mapping].components.any? }
    total_rows   = actionable.sum { |r| r[:parsed].components.size }

    puts "\nScope    : confirmed mappings containing 薑黃 or 代謝"
    puts "Bundles  : #{actionable.size} raw_names with no existing components"
    puts "Rows     : #{total_rows} ProductMappingComponent rows to INSERT"
    puts

    if actionable.empty?
      puts "Nothing to write — all bundles already have components."
      next
    end

    # ── 2. Pre-compute expected deltas ────────────────────────────────
    # Expected increase for turmeric and metabolism after write.
    # Delta = orders whose raw_name will gain a new component for that product.
    #
    # We query actual ShoplineOrder counts (not just occurrence_count) so the
    # post-write validation can compare exact row counts.
    turmeric_id   = CrmProduct.find_by(key: "turmeric")&.id
    metabolism_id = CrmProduct.find_by(key: "metabolism")&.id

    turmeric_primary_names   = turmeric_id   ? ProductNameMapping.confirmed.where(crm_product_id: turmeric_id).pluck(:raw_name) : []
    metabolism_primary_names = metabolism_id ? ProductNameMapping.confirmed.where(crm_product_id: metabolism_id).pluck(:raw_name) : []

    turmeric_new_names = actionable.select { |r|
      r[:parsed].components.any? { |c| c[:product_key] == "turmeric" }
    }.map { |r| r[:mapping].raw_name } - turmeric_primary_names

    metabolism_new_names = actionable.select { |r|
      r[:parsed].components.any? { |c| c[:product_key] == "metabolism" }
    }.map { |r| r[:mapping].raw_name } - metabolism_primary_names

    expected_turmeric_delta   = turmeric_new_names.any?   ? ShoplineOrder.where(product_name: turmeric_new_names).count   : 0
    expected_metabolism_delta = metabolism_new_names.any? ? ShoplineOrder.where(product_name: metabolism_new_names).count : 0

    puts "Expected orders_for delta after write:"
    puts "  turmeric   +#{expected_turmeric_delta}"
    puts "  metabolism +#{expected_metabolism_delta}"
    puts

    # ── 3. Before counts ──────────────────────────────────────────────
    before_turmeric   = ProductNameResolver.orders_for("turmeric").count
    before_metabolism = ProductNameResolver.orders_for("metabolism").count

    puts "Current orders_for counts:"
    puts "  turmeric   #{before_turmeric}"
    puts "  metabolism #{before_metabolism}"
    puts

    # ── 4. Approval gate ──────────────────────────────────────────────
    if ENV["FORCE"] == "true"
      puts "FORCE=true — skipping interactive confirmation"
    else
      puts "Type YES to continue (Ctrl-C or anything else to abort):"
      print "> "
      input = $stdin.gets&.chomp
      unless input == "YES"
        puts "\nAborted. No data written."
        exit(0)
      end
    end
    puts

    # ── 5. Write in a single transaction ──────────────────────────────
    log = { created: 0, skipped_exists: 0, skipped_unknown: 0, failed: 0 }
    rollback_reason = nil

    ActiveRecord::Base.transaction do
      actionable.each do |r|
        mapping = r[:mapping]
        r[:parsed].components.each do |comp|
          crm = CrmProduct.find_by(key: comp[:product_key])
          unless crm
            puts "  [UNKNOWN_PRODUCT] #{mapping.raw_name.inspect}  key=#{comp[:product_key]}"
            log[:skipped_unknown] += 1
            next
          end

          existing = ProductMappingComponent.find_by(
            product_name_mapping_id: mapping.id,
            crm_product_id:          crm.id
          )

          if existing
            puts "  [ALREADY_EXISTS]  #{mapping.raw_name.inspect} → #{comp[:product_key]}"
            log[:skipped_exists] += 1
            next
          end

          begin
            ProductMappingComponent.create!(
              product_name_mapping_id: mapping.id,
              crm_product_id:          crm.id,
              quantity:                comp[:quantity]
            )
            puts "  [CREATED]         #{mapping.raw_name.inspect} → #{comp[:product_key]} qty=#{comp[:quantity]}"
            log[:created] += 1
          rescue ActiveRecord::RecordInvalid => e
            puts "  [FAILED]          #{mapping.raw_name.inspect} → #{comp[:product_key]}  #{e.message}"
            log[:failed] += 1
          end
        end
      end

      # ── 6. Post-write validation ───────────────────────────────────
      puts
      puts "Validating orders_for counts after write..."
      after_turmeric   = ProductNameResolver.orders_for("turmeric").count
      after_metabolism = ProductNameResolver.orders_for("metabolism").count

      actual_turmeric_delta   = after_turmeric   - before_turmeric
      actual_metabolism_delta = after_metabolism - before_metabolism

      puts "  turmeric   #{before_turmeric} → #{after_turmeric}  (#{actual_turmeric_delta >= 0 ? '+' : ''}#{actual_turmeric_delta})"
      puts "  metabolism #{before_metabolism} → #{after_metabolism}  (#{actual_metabolism_delta >= 0 ? '+' : ''}#{actual_metabolism_delta})"

      # Validation: counts must not decrease
      if after_turmeric < before_turmeric
        rollback_reason = "turmeric orders_for decreased (#{before_turmeric} → #{after_turmeric})"
      elsif after_metabolism < before_metabolism
        rollback_reason = "metabolism orders_for decreased (#{before_metabolism} → #{after_metabolism})"
      elsif expected_turmeric_delta > 0 && actual_turmeric_delta != expected_turmeric_delta
        rollback_reason = "turmeric delta mismatch: expected +#{expected_turmeric_delta} got +#{actual_turmeric_delta}"
      elsif expected_metabolism_delta > 0 && actual_metabolism_delta != expected_metabolism_delta
        rollback_reason = "metabolism delta mismatch: expected +#{expected_metabolism_delta} got +#{actual_metabolism_delta}"
      end

      if rollback_reason
        puts "\n  VALIDATION FAILED: #{rollback_reason}"
        puts "  Rolling back entire transaction..."
        raise ActiveRecord::Rollback
      end

      puts "  Validation PASSED"
    end

    # ── 7. Report ─────────────────────────────────────────────────────
    puts
    puts separator
    if rollback_reason
      puts " ROLLBACK — no data written"
      puts " Reason: #{rollback_reason}"
    else
      after_turmeric   = ProductNameResolver.orders_for("turmeric").count
      after_metabolism = ProductNameResolver.orders_for("metabolism").count
      puts " Write complete"
      puts " Created          : #{log[:created]}"
      puts " Already Exists   : #{log[:skipped_exists]}"
      puts " Unknown Product  : #{log[:skipped_unknown]}"
      puts " Failed           : #{log[:failed]}"
      puts
      puts " orders_for after write:"
      puts "   turmeric   #{before_turmeric} → #{after_turmeric}  (+#{after_turmeric - before_turmeric})"
      puts "   metabolism #{before_metabolism} → #{after_metabolism}  (+#{after_metabolism - before_metabolism})"
    end
    puts separator
  end

end
