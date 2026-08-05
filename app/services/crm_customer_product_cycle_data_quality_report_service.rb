# frozen_string_literal: true

# 唯讀資料品質報告：掃描近 LOOKBACK_DAYS 天的有效訂單（ShoplineOrder.valid_paid），
# 列出三類無法可靠建立週期的資料，不寫入任何資料表：
#   - unrecognized_product：品名不屬於任何一個追蹤中的 13 個產品
#   - ambiguous_quantity：產品有比對到，但瓶數解析沒有命中明確的數字/括號
#     樣式，是 BottleExtractor 預設 fallback 出來的 1，不是真的解析出來的
#   - missing_cycle_config：產品與瓶數都確定，但 CrmRepurchaseCycleConfig
#     完全沒有這個產品的週期天數設定（例如歷史樣本數不足的新產品）
class CrmCustomerProductCycleDataQualityReportService
  LOOKBACK_DAYS   = 730
  BRACKET_PATTERN = /[（(](\d+)[瓶盒]/
  SAMPLE_LIMIT    = 20

  def self.call
    new.call
  end

  def call
    unrecognized_product = []
    ambiguous_quantity   = []
    missing_cycle_config = []

    fetch_orders.each do |email, product_name, order_date, order_number|
      product_key = product_key_for(product_name)

      if product_key.nil?
        unrecognized_product << row(email, product_name, order_date, order_number)
        next
      end

      unless quantity_explicit?(product_name, product_key)
        ambiguous_quantity << row(email, product_name, order_date, order_number, product_key: product_key)
      end

      bottle_count = BottleExtractor.call(product_name, product_key)
      if CrmRepurchaseCycleConfig.expected_days(product_key, bottle_count).nil?
        missing_cycle_config << row(email, product_name, order_date, order_number, product_key: product_key, bottle_count: bottle_count)
      end
    end

    {
      window_days:          LOOKBACK_DAYS,
      unrecognized_product: summarize(unrecognized_product),
      ambiguous_quantity:   summarize(ambiguous_quantity),
      missing_cycle_config: summarize(missing_cycle_config)
    }
  end

  private

  def fetch_orders
    since_date = Date.current - LOOKBACK_DAYS
    ShoplineOrder.valid_paid
      .where("order_date >= ?", since_date.beginning_of_day)
      .pluck(:email, :product_name, :order_date, :order_number)
  end

  def matchers
    @matchers ||= CrmProduct.confirmed
      .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
      .pluck(:key, :sql_pattern, :regex_pattern)
      .each_with_object({}) do |(key, sql_pattern, regex_pattern), h|
        h[key] = { substrings: extract_like_substrings(sql_pattern), regex: safe_regex(regex_pattern) }
      end
  end

  def extract_like_substrings(sql_pattern)
    return [] if sql_pattern.blank?

    sql_pattern.scan(/LIKE\s+'%([^%]+)%'/i).flatten
  end

  def safe_regex(pattern)
    return nil if pattern.blank?

    Regexp.new(pattern)
  rescue RegexpError
    nil
  end

  def product_key_for(product_name)
    return nil if product_name.blank?

    matchers.find { |_key, m| m[:substrings].any? { |s| product_name.include?(s) } }&.first
  end

  def quantity_explicit?(product_name, product_key)
    regex = matchers.dig(product_key, :regex)
    (regex && product_name.match?(regex)) || product_name.match?(BRACKET_PATTERN)
  end

  def row(email, product_name, order_date, order_number, product_key: nil, bottle_count: nil)
    {
      email: email, product_name: product_name, order_date: order_date&.to_date,
      order_number: order_number, product_key: product_key, bottle_count: bottle_count
    }
  end

  def summarize(list)
    { count: list.size, sample: list.first(SAMPLE_LIMIT) }
  end
end
