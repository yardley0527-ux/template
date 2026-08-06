# frozen_string_literal: true

require "test_helper"

# Phase 5：CrmProduct 的 alias-aware 比對輔助方法。sql_pattern 不會因為
# CrmProductAlias 新增就自動更新，這幾個方法是唯一正確併入已知 typo 的入口。
class CrmProductMatchingTest < ActiveSupport::TestCase
  def unique_key
    "prod_match_#{SecureRandom.hex(4)}"
  end

  test "matching_substrings 包含 sql_pattern 的子字串與 active_aliases" do
    key = unique_key
    product = CrmProduct.create!(key: key, label: "測試品", status: "confirmed", sql_pattern: "product_name LIKE '%測試品%'")
    CrmProductAlias.create!(crm_product: product, alias_name: "測試品錯字", status: "active", source: "manual")

    substrings = product.matching_substrings
    assert_includes substrings, "測試品"
    assert_includes substrings, "測試品錯字"
  end

  test "matching_substrings 不包含 inactive alias" do
    key = unique_key
    product = CrmProduct.create!(key: key, label: "測試品乙", status: "confirmed", sql_pattern: "product_name LIKE '%測試品乙%'")
    CrmProductAlias.create!(crm_product: product, alias_name: "已停用別名", status: "inactive", source: "manual")

    assert_not_includes product.matching_substrings, "已停用別名"
  end

  test "matching_sql_pattern 沒有 alias 時等於 sql_pattern" do
    key = unique_key
    product = CrmProduct.create!(key: key, label: "測試品丙", status: "confirmed", sql_pattern: "product_name LIKE '%測試品丙%'")
    assert_equal product.sql_pattern, product.matching_sql_pattern
  end

  test "matching_sql_pattern 有 alias 時會用 OR 併入，且能正確查到只有 alias 拼法的訂單" do
    key = unique_key
    product = CrmProduct.create!(key: key, label: "測試品丁", status: "confirmed", sql_pattern: "product_name LIKE '%測試品丁%'")
    # 刻意選一個「不包含」原本 sql_pattern 子字串的錯字拼法（模擬「榖胱甘肽」vs
    # 「穀胱甘肽」這種單字替換的真實 typo，不是加字尾）。
    CrmProductAlias.create!(crm_product: product, alias_name: "丁測品錯字", status: "active", source: "manual")

    ShoplineOrder.create!(order_number: "ORD#{SecureRandom.hex(4)}", email: "a@example.com",
                           product_name: "丁測品錯字2", order_date: Date.current, payment_status: "已付款", quantity: 1)

    assert_equal 1, ShoplineOrder.valid_paid.where(product.matching_sql_pattern).count
    assert_equal 0, ShoplineOrder.valid_paid.where(product.sql_pattern).count
  end

  test "substring_matchers 批次回傳所有指定產品的 matching_substrings，避免逐一查詢" do
    key_a = unique_key
    key_b = unique_key
    product_a = CrmProduct.create!(key: key_a, label: "測試品戊", status: "confirmed", sql_pattern: "product_name LIKE '%測試品戊%'")
    CrmProduct.create!(key: key_b, label: "測試品己", status: "confirmed", sql_pattern: "product_name LIKE '%測試品己%'")
    CrmProductAlias.create!(crm_product: product_a, alias_name: "測試品戊別名", status: "active", source: "manual")

    matchers = CrmProduct.substring_matchers(keys: [key_a, key_b])
    assert_includes matchers[key_a], "測試品戊別名"
    assert_includes matchers[key_b], "測試品己"
  end
end
