# frozen_string_literal: true

require "test_helper"

# 冰晶蕃茄（兩種寫法）與 PDRN 要被購買彙總／系列忠誠度認得。
class SeriesRefreshNewProductsTest < ActiveSupport::TestCase
  def order(email:, number:, product:, date:)
    ShoplineOrder.create!(email: email, order_number: number, product_name: product, order_date: date,
                          payment_status: "已付款", total_amount: 3000, checkout_amount: 3000, quantity: 1)
  end

  setup do
    order(email: "tomato@example.com", number: "T1", product: "冰晶蕃茄3", date: 40.days.ago)
    order(email: "tomato@example.com", number: "T2", product: "冰晶番茄3", date: 10.days.ago)
    order(email: "pdrn@example.com", number: "P1", product: "PDRN5", date: 30.days.ago)
    order(email: "pdrn@example.com", number: "P2", product: "PDRN3", date: 5.days.ago)
  end

  test "series loyalty counts both 蕃茄 and 番茄 spellings under one series, and PDRN" do
    CustomerSeriesLoyaltyRefreshService.call

    tomato = CustomerSeriesLoyalty.find_by!(email: "tomato@example.com", series: "冰晶蕃茄")
    assert_equal 2, tomato.order_count
    assert_equal 2, CustomerSeriesLoyalty.find_by!(email: "pdrn@example.com", series: "PDRN").order_count
  end

  test "purchase summary assigns first/second series and the silent-days threshold" do
    CustomerPurchaseSummaryRefreshService.call

    tomato = CustomerPurchaseSummary.find_by!(email: "tomato@example.com")
    assert_equal "冰晶蕃茄", tomato.first_series
    assert_equal "冰晶蕃茄", tomato.second_series, "番茄 spelling must land in the same series as 蕃茄"
    assert_equal 30, tomato.silent_days_threshold

    pdrn = CustomerPurchaseSummary.find_by!(email: "pdrn@example.com")
    assert_equal "PDRN", pdrn.first_series
    assert_equal 20, pdrn.silent_days_threshold
  end
end
