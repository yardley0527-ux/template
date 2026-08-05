# frozen_string_literal: true

require "test_helper"

class CrmRepurchaseCycleConfigSeedServiceTest < ActiveSupport::TestCase
  def unique_key
    "seed_svc_#{SecureRandom.hex(4)}"
  end

  test "seeds from JourneyProducts::PRODUCTS medians for a legacy-tracked product" do
    # omnipotent 是 JourneyProducts::PRODUCTS 裡既有的 8 個產品之一
    assert JourneyProducts::PRODUCTS.key?("omnipotent")
    CrmProduct.find_or_create_by!(key: "omnipotent") do |p|
      p.label = "全能"; p.status = "confirmed"; p.sql_pattern = "product_name LIKE '%全能%'"
    end
    CrmProduct.where(key: "omnipotent").update_all(status: "confirmed")

    CrmRepurchaseCycleConfigSeedService.call

    medians = JourneyProducts::PRODUCTS.dig("omnipotent", :medians)
    medians.each do |bottle_count, days|
      config = CrmRepurchaseCycleConfig.find_by(product_key: "omnipotent", bottle_count: bottle_count)
      assert config.present?, "missing config for omnipotent/#{bottle_count}"
      assert_equal days, config.median_days
      assert_equal "legacy_journey_products", config.source
    end
  end

  test "excludes mask (面膜) from the target product list" do
    CrmProduct.find_or_create_by!(key: "mask") do |p|
      p.label = "面膜"; p.status = "confirmed"; p.sql_pattern = "product_name LIKE '%面膜%'"
    end
    CrmProduct.where(key: "mask").update_all(status: "confirmed")

    CrmRepurchaseCycleConfigSeedService.call

    assert_equal 0, CrmRepurchaseCycleConfig.where(product_key: "mask").count
  end

  test "skips a non-legacy product with insufficient historical samples (no config rows written)" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試新品", status: "confirmed", sql_pattern: "product_name LIKE '%測試新品%'")

    CrmRepurchaseCycleConfigSeedService.call

    assert_equal 0, CrmRepurchaseCycleConfig.where(product_key: key).count
  end

  test "idempotent: running twice does not duplicate or change rows" do
    CrmProduct.find_or_create_by!(key: "metabolism") do |p|
      p.label = "代謝錠"; p.status = "confirmed"; p.sql_pattern = "product_name LIKE '%代謝%'"
    end
    CrmProduct.where(key: "metabolism").update_all(status: "confirmed")

    CrmRepurchaseCycleConfigSeedService.call
    first_count = CrmRepurchaseCycleConfig.where(product_key: "metabolism").count
    first_ids   = CrmRepurchaseCycleConfig.where(product_key: "metabolism").order(:bottle_count).pluck(:id)

    CrmRepurchaseCycleConfigSeedService.call
    second_count = CrmRepurchaseCycleConfig.where(product_key: "metabolism").count
    second_ids   = CrmRepurchaseCycleConfig.where(product_key: "metabolism").order(:bottle_count).pluck(:id)

    assert_equal first_count, second_count
    assert_equal first_ids, second_ids # 同一批 row，不是刪掉重建
  end
end
