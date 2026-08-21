# frozen_string_literal: true

require "test_helper"

class DandyInventoryReconciliationServiceTest < ActiveSupport::TestCase
  def create_product(key, label, aliases: [])
    product = CrmProduct.create!(key: key, label: label, status: "confirmed",
                                 include_in_analysis: true, source: "test")
    aliases.each do |name|
      product.crm_product_aliases.create!(alias_name: name, normalized_alias: name,
                                          status: "active", source: "seed")
    end
    product
  end

  def snapshot_with_rows(*names_and_realtime)
    rows = names_and_realtime.map { |name, realtime| { "name" => name, "values" => [nil, nil, nil, nil, nil, nil, realtime] } }
    DandyInventorySnapshot.create!(snapshot_date: Date.current, synced_at: Time.current,
                                   data: { "supplements" => { "rows" => rows }, "accessories" => {} })
  end

  test "resolves a DANDY name via an existing active alias" do
    create_product("turmeric", "薑黃", aliases: %w[薑黃])
    snapshot_with_rows(["薑黃", 3009])

    result = DandyInventoryReconciliationService.call

    assert_equal [{ dandy_name: "薑黃", crm_key: "turmeric", realtime: 3009 }], result.mapped
    assert_empty result.unmapped_dandy_rows
  end

  test "resolves the known DANDY-only spelling overrides exactly, without fuzzy matching" do
    create_product("omnipotent", "全能", aliases: %w[全能 B群])
    create_product("mask", "面膜", aliases: %w[面膜 面])
    create_product("vitamin_dk_calcium", "維DK鈣", aliases: %w[維DK鈣 DK鈣])
    snapshot_with_rows(["全能B群", 0], ["外泌體面膜", 471], ["維生素D+鈣", 0])

    result = DandyInventoryReconciliationService.call

    mapped_keys = result.mapped.to_h { |m| [m[:dandy_name], m[:crm_key]] }
    assert_equal "omnipotent",         mapped_keys["全能B群"]
    assert_equal "mask",               mapped_keys["外泌體面膜"]
    assert_equal "vitamin_dk_calcium", mapped_keys["維生素D+鈣"]
    assert_empty result.unmapped_dandy_rows
  end

  test "a DANDY row for a product outside the 13 crm_products is reported unmapped, never guessed" do
    create_product("turmeric", "薑黃", aliases: %w[薑黃])
    snapshot_with_rows(["冰晶番茄", 0], ["美容儀", 50])

    result = DandyInventoryReconciliationService.call

    assert_empty result.mapped
    unmapped_names = result.unmapped_dandy_rows.map { |u| u[:dandy_name] }
    assert_equal %w[冰晶番茄 美容儀].sort, unmapped_names.sort
  end

  test "a crm_product absent from the snapshot is reported in products_without_dandy_row" do
    create_product("turmeric", "薑黃", aliases: %w[薑黃])
    create_product("glutathione", "穀胱甘肽", aliases: %w[穀胱甘肽])
    snapshot_with_rows(["薑黃", 3009])

    result = DandyInventoryReconciliationService.call

    assert_equal ["glutathione"], result.products_without_dandy_row
  end

  test "two DANDY rows resolving to the same product are flagged as a duplicate target, not silently merged" do
    create_product("omnipotent", "全能", aliases: %w[全能])
    snapshot_with_rows(["全能", 10], ["全能膠囊", 5])
    # simulate a collision: add a second alias that happens to also match a row name
    CrmProduct.find_by(key: "omnipotent").crm_product_aliases.create!(
      alias_name: "全能膠囊", normalized_alias: "全能膠囊", status: "active", source: "seed"
    )

    result = DandyInventoryReconciliationService.call

    assert_equal 1, result.duplicate_targets.size
    dup = result.duplicate_targets.first
    assert_equal "omnipotent", dup[:crm_key]
    assert_equal %w[全能 全能膠囊].sort, dup[:dandy_names].sort
  end

  test "no snapshot yet returns every confirmed product as without_dandy_row and nothing mapped" do
    create_product("turmeric", "薑黃", aliases: %w[薑黃])

    result = DandyInventoryReconciliationService.call

    assert_nil result.snapshot_date
    assert_empty result.mapped
    assert_equal ["turmeric"], result.products_without_dandy_row
  end
end
