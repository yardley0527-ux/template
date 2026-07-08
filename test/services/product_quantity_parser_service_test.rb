# frozen_string_literal: true

require "test_helper"

class ProductQuantityParserServiceTest < ActiveSupport::TestCase
  setup do
    create_product("omnipotent",  "全能",     '全能(\d+)')
    create_product("metabolism",  "代謝錠",   '代謝錠?(\d+)')
    create_product("turmeric",    "薑黃",     '薑黃(\d+)')
    create_product("whitening",   "美白",     '美白(\d+)')
    create_product("collagen",    "膠原蛋白", '膠原(?:蛋白)?(\d+)')
    create_product("glutathione", "穀胱甘肽", '穀胱甘肽(\d+)')
    create_product("mask",        "面膜",     '面膜(\d+)')
  end

  def create_product(key, label, regex_pattern)
    CrmProduct.create!(
      key: "qp_#{key}", label: label, status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: regex_pattern
    )
  end

  def components_for(raw_name)
    ProductQuantityParserService.call(raw_name).components
  end

  test "全能1 → single product, paid 1 gift 0" do
    components = components_for("全能1")

    assert_equal 1, components.size
    assert_equal({ crm_product_key: "qp_omnipotent", crm_product_label: "全能",
                    paid_quantity: 1, gift_quantity: 0, total_quantity: 1 }, components.first)
  end

  test "全能6 → single product, paid 6 gift 0" do
    components = components_for("全能6")

    assert_equal({ crm_product_key: "qp_omnipotent", crm_product_label: "全能",
                    paid_quantity: 6, gift_quantity: 0, total_quantity: 6 }, components.first)
  end

  test "全能10送2 → paid 10 gift 2 (bare gift addition to same product)" do
    components = components_for("全能10送2")

    assert_equal 1, components.size
    assert_equal({ crm_product_key: "qp_omnipotent", crm_product_label: "全能",
                    paid_quantity: 10, gift_quantity: 2, total_quantity: 12 }, components.first)
  end

  test "代謝錠2送1 → paid 2 gift 1" do
    components = components_for("代謝錠2送1")

    assert_equal({ crm_product_key: "qp_metabolism", crm_product_label: "代謝錠",
                    paid_quantity: 2, gift_quantity: 1, total_quantity: 3 }, components.first)
  end

  test "薑黃1全能1 → two independent products, no gift" do
    components = components_for("薑黃1全能1")

    by_key = components.index_by { |c| c[:crm_product_key] }
    assert_equal 2, components.size
    assert_equal({ crm_product_key: "qp_turmeric", crm_product_label: "薑黃",
                    paid_quantity: 1, gift_quantity: 0, total_quantity: 1 }, by_key["qp_turmeric"])
    assert_equal({ crm_product_key: "qp_omnipotent", crm_product_label: "全能",
                    paid_quantity: 1, gift_quantity: 0, total_quantity: 1 }, by_key["qp_omnipotent"])
  end

  test "美白1膠原蛋白1 → two independent products, no gift" do
    components = components_for("美白1膠原蛋白1")

    by_key = components.index_by { |c| c[:crm_product_key] }
    assert_equal 2, components.size
    assert_equal 1, by_key["qp_whitening"][:paid_quantity]
    assert_equal 1, by_key["qp_collagen"][:paid_quantity]
    assert_equal 0, by_key["qp_whitening"][:gift_quantity]
    assert_equal 0, by_key["qp_collagen"][:gift_quantity]
  end

  test "穀胱甘肽10送2送面膜1 → glutathione paid 10 gift 2, mask paid 0 gift 1 (gift attaches to a different product)" do
    components = components_for("穀胱甘肽10送2送面膜1")

    by_key = components.index_by { |c| c[:crm_product_key] }
    assert_equal 2, components.size
    assert_equal({ crm_product_key: "qp_glutathione", crm_product_label: "穀胱甘肽",
                    paid_quantity: 10, gift_quantity: 2, total_quantity: 12 }, by_key["qp_glutathione"])
    assert_equal({ crm_product_key: "qp_mask", crm_product_label: "面膜",
                    paid_quantity: 0, gift_quantity: 1, total_quantity: 1 }, by_key["qp_mask"])
  end

  test "代謝錠12送全能2 → gift attaches to the different product it names (real Epic C data case)" do
    components = components_for("代謝錠12送全能2")

    by_key = components.index_by { |c| c[:crm_product_key] }
    assert_equal({ paid_quantity: 12, gift_quantity: 0 }.values,
                 [by_key["qp_metabolism"][:paid_quantity], by_key["qp_metabolism"][:gift_quantity]])
    assert_equal({ paid_quantity: 0, gift_quantity: 2 }.values,
                 [by_key["qp_omnipotent"][:paid_quantity], by_key["qp_omnipotent"][:gift_quantity]])
  end

  test "blank raw_name returns no components" do
    assert_equal [], components_for("")
    assert_equal [], components_for(nil)
  end

  test "raw_name matching no product returns no components" do
    assert_equal [], components_for("完全不存在的商品XYZ")
  end

  test "a product mentioned twice only counts the first occurrence (inherited find_matches_with_spans behavior)" do
    components = components_for("全能1全能2")

    assert_equal 1, components.size
    assert_equal 1, components.first[:paid_quantity]
  end

  # ── Bracket fallback (E3-2.1) ─────────────────────────────────────────

  test "bracket fallback: 全能（10瓶送2） → paid 10 gift 2" do
    components = components_for("全能（10瓶送2）")

    assert_equal 1, components.size
    assert_equal({ crm_product_key: "qp_omnipotent", crm_product_label: "全能",
                    paid_quantity: 10, gift_quantity: 2, total_quantity: 12 }, components.first)
  end

  test "bracket fallback: DK鈣（10盒） and 維DK鈣（10盒） both → paid 10 gift 0" do
    create_product("vitamin_dk_calcium", "維DK鈣", '維?DK鈣(\d+)')

    ["DK鈣（10盒）", "維DK鈣（10盒）"].each do |raw|
      components = components_for(raw)
      assert_equal 1, components.size, "expected one component for #{raw}"
      assert_equal 10, components.first[:paid_quantity]
      assert_equal 0,  components.first[:gift_quantity]
    end
  end

  test "bracket fallback: 代謝錠（2瓶送1） → paid 2 gift 1, and half-width bracket works" do
    assert_equal [{ crm_product_key: "qp_metabolism", crm_product_label: "代謝錠",
                     paid_quantity: 2, gift_quantity: 1, total_quantity: 3 }],
                 components_for("代謝錠（2瓶送1）")
    assert_equal 2, components_for("代謝錠(2瓶)").first[:paid_quantity]
  end

  test "bracket fallback never double-counts a product the primary regex already matched" do
    components = components_for("全能6")

    assert_equal 1, components.size
    assert_equal 6, components.first[:paid_quantity]
  end

  test "bracket without 瓶/盒 unit is not treated as a quantity" do
    assert_equal [], components_for("全能（10）")
  end

  test "bracket fallback allows whitespace between name and bracket: 益生菌 （3盒送1）" do
    create_product("probiotic", "益生菌", '益生菌(\d+)')

    components = components_for("益生菌 （3盒送1）")

    assert_equal 1, components.size
    assert_equal 3, components.first[:paid_quantity]
    assert_equal 1, components.first[:gift_quantity]
  end

  test "accepts a pre-loaded products array instead of querying" do
    products = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a

    result = ProductQuantityParserService.call("全能10送2", products: products)

    assert_equal 10, result.components.first[:paid_quantity]
    assert_equal 2,  result.components.first[:gift_quantity]
  end
end
