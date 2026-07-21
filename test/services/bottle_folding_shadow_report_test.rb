# frozen_string_literal: true

require "test_helper"

class BottleFoldingShadowReportTest < ActiveSupport::TestCase
  setup do
    # BottleExtractor 從 crm_products.regex_pattern 取 regex（production 已有值）
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed",
                       regex_pattern: '(?:代謝錠錠|代謝錠|代謝定|代謝)(\d+)')
  end

  def create_line(email:, order_number:, product_name:, quantity: 1, days_ago: 10,
                  checkout_amount: 1000, total_amount: nil)
    ShoplineOrder.create!(
      email: email, order_number: order_number, product_name: product_name,
      quantity: quantity, checkout_amount: checkout_amount, total_amount: total_amount,
      payment_status: "已付款", order_date: days_ago.days.ago
    )
  end

  def report_row(email)
    report = BottleFoldingShadowReport.call(product_key: "metabolism")
    report[:rows].find { |r| r[:email] == email }
  end

  test "household override: current misses it, extractor catches 6" do
    create_line(email: "a@x.com", order_number: "#A1",
                product_name: "比利時超代謝精華錠｜500顆家庭號")

    row = report_row("a@x.com")
    assert_equal 1, row[:v1_current]
    assert_equal 6, row[:v2_extractor]
    assert_equal 6, row[:v6_order_fold]
    assert_includes row[:reasons], "household_override"
    # medians 1→30 / 3+→90：預期回購日往後移 60 天
    assert_equal 60, (row[:expected_v6] - row[:expected_v1]).to_i
  end

  test "quantity is multiplied in v3/v6 but ignored by current logic" do
    create_line(email: "b@x.com", order_number: "#B1", product_name: "代謝錠1", quantity: 3)

    row = report_row("b@x.com")
    assert_equal 1, row[:v1_current]
    assert_equal 1, row[:v2_extractor]
    assert_equal 3, row[:v3_qty]
    assert_equal 3, row[:v6_order_fold]
    assert_includes row[:reasons], "quantity_multiplier"
  end

  test "same-day multiple orders are summed by v6, current takes only the last line" do
    create_line(email: "c@x.com", order_number: "#C1", product_name: "代謝錠2", days_ago: 5)
    create_line(email: "c@x.com", order_number: "#C2", product_name: "代謝錠1", days_ago: 5)

    row = report_row("c@x.com")
    assert_equal 2, row[:day_order_count]
    assert_includes row[:reasons], "same_day_multiple_orders"
    assert_equal 3, row[:v6_order_fold]
    assert_equal 2, row[:v4_day_max]
    assert_equal 3, row[:v5_day_sum]
    # v1 只看「最後一列」：兩列同日，取其中一列（1 或 2 瓶）
    assert_includes [1, 2], row[:v1_current]
  end

  test "identical lines in one order are flagged, not collapsed" do
    create_line(email: "d@x.com", order_number: "#D1", product_name: "代謝錠3",
                checkout_amount: 5500)
    create_line(email: "d@x.com", order_number: "#D1", product_name: "代謝錠3",
                checkout_amount: 5500)

    row = report_row("d@x.com")
    assert_includes row[:reasons], "same_order_duplicate_candidate"
    # 不做 DISTINCT 摺疊：兩列都計（可能是真實買兩組），交由人工核對
    assert_equal 6, row[:v6_order_fold]
  end

  test "bundle line crossing products is tagged bundle_multi_product and gift" do
    create_line(email: "e@x.com", order_number: "#E1",
                product_name: "代謝錠1薑黃1送清纖粉1")

    row = report_row("e@x.com")
    assert_includes row[:reasons], "bundle_multi_product"
    assert_includes row[:reasons], "gift"
    assert_equal 1, row[:v1_current]
  end

  test "summary counts changed rows and reasons without touching tracking tables" do
    create_line(email: "f@x.com", order_number: "#F1", product_name: "代謝錠1", quantity: 2)
    create_line(email: "g@x.com", order_number: "#G1", product_name: "代謝錠2")

    tracking_count = lambda do
      ActiveRecord::Base.connection
        .select_value("SELECT COUNT(*) FROM crm_customer_product_trackings").to_i
    end
    before = tracking_count.call

    report = BottleFoldingShadowReport.call(product_key: "metabolism")
    summary = report[:summary]

    assert_equal 2, summary[:total_rows]
    assert_equal 1, summary[:changed_rows] # 只有 f@x.com 因 quantity 改變
    assert_equal({ "quantity_multiplier" => 1 }, summary[:reason_counts])
    assert summary[:shift_distribution].is_a?(Hash)
    assert_equal before, tracking_count.call
  end
end
