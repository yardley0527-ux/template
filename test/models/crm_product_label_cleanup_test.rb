# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20260708120000_align_crm_product_display_labels"

class CrmProductLabelCleanupTest < ActiveSupport::TestCase
  def run_migration(direction)
    # Suppress "== AlignCrmProductDisplayLabels: migrating ==" chatter in test output.
    migration = AlignCrmProductDisplayLabels.new
    migration.instance_variable_set(:@output, nil)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def create_product(key, label)
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                       include_in_analysis: true, source: "test")
  end

  test "up renames the two diverged labels" do
    collagen   = create_product("collagen",   "膠原飲")
    omnipotent = create_product("omnipotent", "B群／全能")

    run_migration(:up)

    assert_equal "膠原蛋白", collagen.reload.label
    assert_equal "全能",     omnipotent.reload.label
  end

  test "up leaves a row alone when a human already renamed it" do
    collagen = create_product("collagen", "膠原蛋白PLUS")

    run_migration(:up)

    assert_equal "膠原蛋白PLUS", collagen.reload.label
  end

  test "up touches only label — key/regex/sql/aliases untouched" do
    omnipotent = create_product("omnipotent", "B群／全能")
    omnipotent.update!(regex_pattern: '全能(\d+)', sql_pattern: "product_name LIKE '%全能%'")
    omnipotent.crm_product_aliases.create!(alias_name: "全能", normalized_alias: "全能",
                                           status: "active", source: "seed")

    run_migration(:up)

    omnipotent.reload
    assert_equal "omnipotent",                   omnipotent.key
    assert_equal '全能(\d+)',                    omnipotent.regex_pattern
    assert_equal "product_name LIKE '%全能%'",   omnipotent.sql_pattern
    assert_equal ["全能"],                       omnipotent.crm_product_aliases.pluck(:alias_name)
  end

  test "down restores the original labels" do
    collagen   = create_product("collagen",   "膠原蛋白")
    omnipotent = create_product("omnipotent", "全能")

    run_migration(:down)

    assert_equal "膠原飲",    collagen.reload.label
    assert_equal "B群／全能", omnipotent.reload.label
  end

  test "JourneyProducts seed source carries the new labels (bootstrap won't write old names back)" do
    assert_equal "全能",     JourneyProducts::PRODUCTS.fetch("omnipotent")[:label]
    assert_equal "膠原蛋白", JourneyProducts::PRODUCTS.fetch("collagen")[:label]
  end

  test "bootstrap and candidate-generator product definitions inherit the new labels" do
    bootstrap_labels = ProductRegistryBootstrapService::ALL_PRODUCTS
      .to_h { |p| [p[:key], p[:label]] }
    generator_labels = ProductCandidateGeneratorService::KNOWN_PRODUCTS
      .to_h { |p| [p[:key], p[:label]] }

    assert_equal "全能",     bootstrap_labels.fetch("omnipotent")
    assert_equal "膠原蛋白", bootstrap_labels.fetch("collagen")
    assert_equal "全能",     generator_labels.fetch("omnipotent")
    assert_equal "膠原蛋白", generator_labels.fetch("collagen")
  end

  test "series_labels_for_filter returns aligned labels after rename (override becomes a no-op)" do
    create_product("collagen",   "膠原蛋白")
    create_product("omnipotent", "全能")

    labels = CrmProduct.series_labels_for_filter

    assert_includes labels, "膠原蛋白"
    assert_includes labels, "全能"
  end
end
