# frozen_string_literal: true

require "test_helper"

class YardleyPromotionScraperServiceTest < ActiveSupport::TestCase
  def product_item(name:, url:, regular_price:, sale_price: nil)
    price_block =
      if sale_price
        <<~HTML
          <div class="price__sale sl-price primary-color-price price price-sale ">NT$#{sale_price}</div>
          <div class="price__regular"><span class="price price-crossed">NT$#{regular_price}</span></div>
        HTML
      else
        <<~HTML
          <div class="price__regular"><span class="price">NT$#{regular_price}</span></div>
        HTML
      end

    <<~HTML
      <div class="product-item">
        <a href="#{url}" class="quick-cart-item">
          <div class="info-box">
            <div class="title">#{name}</div>
            <div class="quick-cart-price">#{price_block}</div>
          </div>
        </a>
      </div>
    HTML
  end

  def page(*items)
    "<html><body><div class=\"ProductList-list\">#{items.join}</div></body></html>"
  end

  test "records a snapshot with computed discount_pct for a discounted product" do
    html = page(product_item(
      name: "韓國專利 LAB2PRO 1000億益生菌（2盒）",
      url: "https://www.yardley.tw/products/probiotic-2boxes",
      regular_price: 4360, sale_price: 3900
    ))

    assert YardleyPromotionScraperService.call(html: html)

    snapshot = ProductPromotionSnapshot.find_by(product_key: "probiotic")
    assert_equal 4360, snapshot.regular_price
    assert_equal 3900, snapshot.sale_price
    assert_equal 10.6, snapshot.discount_pct.to_f
    assert snapshot.on_sale?
  end

  test "a product with no sale price records discount_pct of 0" do
    html = page(product_item(
      name: "維生素B鋅C 全能膠囊", url: "https://www.yardley.tw/products/b-complex",
      regular_price: 1880
    ))

    YardleyPromotionScraperService.call(html: html)

    snapshot = ProductPromotionSnapshot.find_by(product_key: "omnipotent")
    assert_equal 0.0, snapshot.discount_pct.to_f
    assert_not snapshot.on_sale?
  end

  test "when multiple bundle tiers match the same product_key, keeps the largest discount" do
    html = page(
      product_item(name: "韓國專利 LAB2PRO 1000億益生菌", url: "https://www.yardley.tw/products/probiotic-1box",
                   regular_price: 2180),
      product_item(name: "韓國專利 LAB2PRO 1000億益生菌（5盒）", url: "https://www.yardley.tw/products/probiotic-5boxes",
                   regular_price: 17440, sale_price: 10900)
    )

    YardleyPromotionScraperService.call(html: html)

    snapshot = ProductPromotionSnapshot.find_by(product_key: "probiotic")
    assert_equal 37.5, snapshot.discount_pct.to_f
    assert_equal "韓國專利 LAB2PRO 1000億益生菌（5盒）", snapshot.product_name
  end

  test "an unmatched product does not create a snapshot for any tracked key" do
    html = page(product_item(name: "無關商品", url: "https://www.yardley.tw/products/unrelated",
                              regular_price: 999))

    YardleyPromotionScraperService.call(html: html)

    assert_empty ProductPromotionSnapshot.all
  end

  test "empty page produces no snapshots and still returns true" do
    assert YardleyPromotionScraperService.call(html: "<html><body></body></html>")
    assert_empty ProductPromotionSnapshot.all
  end
end
