# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleDataQualityReportServiceTest < ActiveSupport::TestCase
  def unique_key
    "dq_#{SecureRandom.hex(4)}"
  end

  def make_order(email:, product_name:, order_date: Date.current - 10, payment_status: "已付款")
    ShoplineOrder.create!(
      order_number: "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: payment_status, quantity: 1
    )
  end

  test "flags a product_name that matches no tracked product" do
    order = make_order(email: "a@example.com", product_name: "完全沒對應的商品名稱")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
  end

  test "excludes refunded/unpaid orders from the report entirely" do
    order = make_order(email: "a@example.com", product_name: "完全沒對應的商品名稱2", payment_status: "已退款")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end

  test "flags ambiguous quantity when neither the product's regex nor the bracket pattern matches" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品%'", regex_pattern: "測試品質商品(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品") # 沒有數字

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:ambiguous_quantity][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
    assert_equal key, hit[:product_key]
  end

  test "does not flag ambiguous quantity when the regex explicitly matches" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品乙", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品乙%'", regex_pattern: "測試品質商品乙(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品乙3")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:ambiguous_quantity][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end

  test "flags orders_missing_cycle_config when the product has no repurchase cycle config at all" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品丙", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品丙%'", regex_pattern: "測試品質商品丙(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品丙2")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:orders_missing_cycle_config][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
    assert_equal 2, hit[:bottle_count]
  end

  test "does not flag orders_missing_cycle_config once a config row exists for that bucket" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品丁", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品丁%'", regex_pattern: "測試品質商品丁(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 2, median_days: 45, source: "manual")
    order = make_order(email: "a@example.com", product_name: "測試品質商品丁2")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:orders_missing_cycle_config][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end

  test "a product with zero historical orders and zero cycle config still appears in products_missing_cycle_config (冰晶番茄情境)" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試新品戊", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試新品戊%'", regex_pattern: "測試新品戊(\\d+)")
    # 刻意不建立任何訂單、也不建立任何 CrmRepurchaseCycleConfig

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:products_missing_cycle_config].find { |p| p[:product_key] == key }
    assert hit.present?, "零訂單、零週期設定的產品必須出現在 products_missing_cycle_config，不能被靜默排除"
    assert_equal "測試新品戊", hit[:label]
  end

  test "products_missing_cycle_config excludes mask (面膜) and excludes products that already have a config row" do
    key_configured = unique_key
    CrmProduct.create!(key: key_configured, label: "測試已設定產品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試已設定產品%'")
    CrmRepurchaseCycleConfig.create!(product_key: key_configured, bottle_count: 1, median_days: 30, source: "manual")

    CrmProduct.find_or_create_by!(key: "mask") do |p|
      p.label = "面膜"; p.status = "confirmed"; p.sql_pattern = "product_name LIKE '%面膜%'"
    end
    CrmProduct.where(key: "mask").update_all(status: "confirmed")

    report = CrmCustomerProductCycleDataQualityReportService.call
    keys = report[:products_missing_cycle_config].map { |p| p[:product_key] }
    assert_not_includes keys, key_configured
    assert_not_includes keys, "mask"
  end

  test "orders_missing_cycle_config (訂單層級) and products_missing_cycle_config (產品層級) are independent counts" do
    # 有訂單、缺該瓶數設定 vs 完全沒有訂單、缺全部設定，是兩件不同的事，不能混在一起算
    ordered_key = unique_key
    CrmProduct.create!(key: ordered_key, label: "測試訂單層級品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試訂單層級品%'", regex_pattern: "測試訂單層級品(\\d+)")
    make_order(email: "a@example.com", product_name: "測試訂單層級品5")

    zero_order_key = unique_key
    CrmProduct.create!(key: zero_order_key, label: "測試零訂單品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試零訂單品%'")

    report = CrmCustomerProductCycleDataQualityReportService.call
    order_level_keys   = report[:orders_missing_cycle_config][:sample].map { |r| r[:product_key] }
    product_level_keys = report[:products_missing_cycle_config].map { |p| p[:product_key] }

    assert_includes order_level_keys, ordered_key
    # 產品層級判斷只看「有沒有任何 config」，跟有沒有訂單無關——兩個 key 都沒建
    # config，所以都要出現在這裡（即使 ordered_key 已經有訂單資料）。
    assert_includes product_level_keys, ordered_key
    assert_includes product_level_keys, zero_order_key
  end

  # ── Phase 5：ignored_product 分類 ──────────────────────────────────

  test "面膜（明確不追蹤但已知的商品）歸類為 ignored_product，不計入 unrecognized_product" do
    CrmProduct.find_or_create_by!(key: "mask") do |p|
      p.label = "面膜"; p.status = "confirmed"; p.sql_pattern = "product_name LIKE '%面膜%'"
    end
    CrmProduct.where(key: "mask").update_all(status: "confirmed")
    order = make_order(email: "a@example.com", product_name: "面膜3")

    report = CrmCustomerProductCycleDataQualityReportService.call
    assert_nil report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert report[:ignored_product][:sample].find { |r| r[:order_number] == order.order_number }.present?
  end

  test "KNOWN_UNTRACKED_KEYWORDS 登記的品名歸類為 ignored_product" do
    order = make_order(email: "a@example.com", product_name: "蔓越莓D-甘露糖粉")

    report = CrmCustomerProductCycleDataQualityReportService.call
    assert_nil report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert report[:ignored_product][:sample].find { |r| r[:order_number] == order.order_number }.present?
  end

  test "已登記在 CrmProductAlias 的已知 typo 不再計入 unrecognized_product" do
    key = unique_key
    product = CrmProduct.create!(key: key, label: "測試品質商品戊", status: "confirmed",
                                  sql_pattern: "product_name LIKE '%測試品質商品戊%'", regex_pattern: "測試品質商品戊(\\d+)")
    CrmProductAlias.create!(crm_product: product, alias_name: "品質戊錯字", status: "active", source: "manual")
    order = make_order(email: "a@example.com", product_name: "品質戊錯字2")

    report = CrmCustomerProductCycleDataQualityReportService.call
    assert_nil report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
  end
end
