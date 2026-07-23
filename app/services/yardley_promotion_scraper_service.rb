# frozen_string_literal: true

require "net/http"

# Scrapes the yardley.tw product listing page and records one
# ProductPromotionSnapshot per JourneyProducts key per run, so
# NotificationRules::PromotionOpportunity can diff today's snapshot against
# the previous one to detect a promotion that just started.
#
# Matching a scraped product to a JourneyProducts key reuses the same
# substring check as JourneyProducts::PRODUCTS[key][:sql] (LIKE '%label%'),
# so there is only one place that defines what counts as e.g. "益生菌" —
# no separate alias table. Bundle-tier variants (buy-2/3/5/7-boxes pages)
# all map to the same key; the one with the largest discount wins, since
# that is the deal worth telling customers about.
#
# html: is an injection point for tests — pass a fixture string instead of
# hitting the network. Rails.env.test? guards against ever having to.
class YardleyPromotionScraperService
  CATEGORY_URL = "https://www.yardley.tw/categories/products"
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

  def self.call(html: nil)
    new(html: html).call
  end

  def initialize(html: nil)
    @html = html
  end

  def call
    products = parse(@html || fetch_html)
    save_snapshots(products)
  rescue StandardError => e
    Rails.logger.error("[YardleyPromotionScraperService] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_html
    uri = URI(CATEGORY_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = USER_AGENT

    response = http.request(request)
    response.body.force_encoding("UTF-8")
  end

  def parse(body)
    Nokogiri::HTML(body).css(".product-item").filter_map { |item| parse_item(item) }
  end

  def parse_item(item)
    name = item.at_css(".title")&.text&.strip
    url  = item.at_css("a.quick-cart-item")&.attr("href")
    return nil if name.blank? || url.blank?

    regular_price = parse_price(item.at_css(".price__regular .price")&.text)
    return nil if regular_price.blank? || regular_price.zero?

    sale_el    = item.at_css(".price__sale")
    sale_price = sale_el ? parse_price(sale_el.text) : regular_price
    return nil if sale_price.blank?

    discount_pct = sale_price < regular_price ? ((1 - sale_price.to_f / regular_price) * 100).round(1) : 0.0

    { name: name, url: url, regular_price: regular_price, sale_price: sale_price, discount_pct: discount_pct }
  end

  def parse_price(text)
    return nil if text.blank?

    text.gsub(/[^\d]/, "").to_i
  end

  def save_snapshots(products)
    now = Time.current

    JourneyProducts::PRODUCTS.each do |product_key, config|
      matches = products.select { |p| matches_product?(p[:name], config) }
      next if matches.empty?

      best = matches.max_by { |p| p[:discount_pct] }
      ProductPromotionSnapshot.create!(
        product_key:   product_key,
        product_name:  best[:name],
        product_url:   best[:url],
        regular_price: best[:regular_price],
        sale_price:    best[:sale_price],
        discount_pct:  best[:discount_pct],
        scraped_at:    now
      )
    end

    true
  end

  def matches_product?(name, config)
    name.include?(config[:label]) || name.include?(config[:short])
  end
end
