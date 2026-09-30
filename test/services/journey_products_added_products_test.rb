# frozen_string_literal: true

require "test_helper"

# 9/30 加入回購追蹤的 4 個產品：魚油、蝦紅素、PDRN、冰晶蕃茄。
# 驗證訂單品名（含「番茄／蕃茄」兩種寫法、「預購-」前綴、「送N」）都能被認出來，
# 瓶數與回購天數（medians）算得對。
class JourneyProductsAddedProductsTest < ActiveSupport::TestCase
  def track(product_key, product_name, email: "buyer@example.com")
    ShoplineCustomer.create!(email: email)
    order = ShoplineOrder.create!(email: email, order_date: 10.days.ago, product_name: product_name, checkout_amount: 1000)
    CrmCustomerProductTrackingRefreshService.call(product_key: product_key)
    [CrmCustomerProductTracking.find_by!(email: email, product_key: product_key), order.order_date.to_date]
  end

  test "the four added products are registered with the same keys as crm_products" do
    %w[fish_oil astaxanthin pdrn iced_tomato].each do |key|
      assert JourneyProducts::PRODUCTS.key?(key), "#{key} missing from JourneyProducts::PRODUCTS"
      assert_equal key, JourneyProducts::PRODUCTS.fetch(key)[:key]
    end
  end

  test "fish oil: bottle count from the name and the historical median days" do
    row, order_date = track("fish_oil", "魚油3")

    assert_equal 3, row.last_order_bottles
    assert_equal order_date + 114, row.expected_return_date
  end

  test "fish oil: the long product-name form falls back to the bottle count in parentheses" do
    row, order_date = track("fish_oil", "98%高濃度頂級專利黃金魚油(12盒)")

    assert_equal 12, row.last_order_bottles
    assert_equal order_date + 157, row.expected_return_date, "above the largest tier uses the largest tier's median"
  end

  test "astaxanthin: gift bottles in 10送4 count toward the bottle total" do
    row, order_date = track("astaxanthin", "蝦紅素10送4")

    assert_equal 14, row.last_order_bottles
    assert_equal order_date + 153, row.expected_return_date
  end

  test "pdrn: 12.5 days per bottle" do
    { "PDRN1" => 13, "PDRN3" => 38, "PDRN10" => 125 }.each_with_index do |(name, days), i|
      row, order_date = track("pdrn", name, email: "pdrn#{i}@example.com")
      assert_equal order_date + days, row.expected_return_date, name
    end
  end

  test "iced tomato: matches both 番茄 and 蕃茄 spellings and the 預購- prefix" do
    { "冰晶番茄1" => "a@example.com", "冰晶蕃茄3" => "b@example.com", "預購-冰晶蕃茄10送1" => "c@example.com" }.each do |name, email|
      ShoplineCustomer.create!(email: email)
      ShoplineOrder.create!(email: email, order_date: 10.days.ago, product_name: name, checkout_amount: 1000)
    end
    CrmCustomerProductTrackingRefreshService.call(product_key: "iced_tomato")

    rows = CrmCustomerProductTracking.where(product_key: "iced_tomato").index_by(&:email)
    assert_equal 3, rows.size, "all three spellings are tracked"
    assert_equal 1, rows["a@example.com"].last_order_bottles
    assert_equal 3, rows["b@example.com"].last_order_bottles
    assert_equal 11, rows["c@example.com"].last_order_bottles, "10送1 counts the gift bottle"
  end

  test "iced tomato: pre-order customers count from the 9/25 arrival date, not the order date" do
    ShoplineCustomer.create!(email: "pre@example.com")
    ShoplineOrder.create!(email: "pre@example.com", order_date: Time.utc(2026, 7, 25, 4), product_name: "預購-冰晶蕃茄1", checkout_amount: 2750)
    ShoplineCustomer.create!(email: "stock@example.com")
    ShoplineOrder.create!(email: "stock@example.com", order_date: Time.utc(2026, 7, 25, 4), product_name: "冰晶蕃茄1", checkout_amount: 2750)

    travel_to Time.utc(2026, 9, 30, 4) do
      CrmCustomerProductTrackingRefreshService.call(product_key: "iced_tomato")
    end

    pre = CrmCustomerProductTracking.find_by!(email: "pre@example.com", product_key: "iced_tomato")
    stock = CrmCustomerProductTracking.find_by!(email: "stock@example.com", product_key: "iced_tomato")
    assert_equal Date.new(2026, 9, 25), pre.last_order_date
    assert_equal Date.new(2026, 9, 25) + 45, pre.expected_return_date
    assert_equal Date.new(2026, 7, 25), stock.last_order_date, "in-stock orders still count from the order date"
  end

  test "iced tomato reuses the whitening historical medians" do
    row, order_date = track("iced_tomato", "冰晶蕃茄3")

    assert_equal order_date + 54, row.expected_return_date
  end
end
