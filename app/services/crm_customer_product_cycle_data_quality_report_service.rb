# frozen_string_literal: true

# 唯讀資料品質報告：掃描近 LOOKBACK_DAYS 天的有效訂單（ShoplineOrder.valid_paid），
# 列出無法可靠建立週期的資料，不寫入任何資料表：
#   - unrecognized_product：品名真的無法判斷屬於哪個產品（含追蹤中跟明確
#     不追蹤的都對不上）——這是唯一需要人工判斷的類別
#   - ignored_product：品名對應到「已知但明確不追蹤」的商品（面膜等
#     confirmed 但被排除在 13 個追蹤產品外的 CrmProduct，或
#     KNOWN_UNTRACKED_KEYWORDS 裡登記的其他已知商品）——Phase 5 修正：
#     這類不該跟真正無法辨識的品名混在一起算進 unrecognized_product
#   - ambiguous_quantity：產品有比對到，但瓶數解析沒有命中明確的數字/括號
#     樣式，是 BottleExtractor 預設 fallback 出來的 1，不是真的解析出來的
#   - orders_missing_cycle_config：產品與瓶數都確定，但 CrmRepurchaseCycleConfig
#     沒有這個產品/瓶數的週期天數設定（訂單層級，只看得到「有訂單」的產品）
#   - products_missing_cycle_config：13 個追蹤產品裡，完全沒有任何
#     CrmRepurchaseCycleConfig 列的產品（產品層級，即使 0 筆歷史訂單也會
#     出現——不然新產品因為掃不到訂單，永遠不會被前一類報告抓到，會被
#     靜默排除。Phase 1.5 修正：冰晶番茄這種案例必須明確出現在這裡）
#
# Phase 5 修正：產品比對改用 CrmProduct#matching_substrings / .matching_sql_pattern
# （sql_pattern + CrmProductAlias 已知別名），不再只看 sql_pattern——「榖胱甘肽」
# 「益生箘」這類已經登記在 alias 表的已知 typo，本來會被誤判成 unrecognized_product。
class CrmCustomerProductCycleDataQualityReportService
  LOOKBACK_DAYS   = 730
  BRACKET_PATTERN = /[（(](\d+)[瓶盒]/
  SAMPLE_LIMIT    = 20

  # 明確存在、但不是任何一個 CrmProduct（含 mask）的商品名稱關鍵字，人工核可
  # 才能加進來——不可用來掩蓋真正不確定的品名。目前只有「蔓越莓D-甘露糖粉」
  # 這種一望即知是別的商品線、不是 typo 也不是我們產品的案例。
  KNOWN_UNTRACKED_KEYWORDS = %w[蔓越莓].freeze

  def self.call
    new.call
  end

  def call
    unrecognized_product        = []
    ignored_product              = []
    ambiguous_quantity          = []
    orders_missing_cycle_config = []

    fetch_orders.each do |email, product_name, order_date, order_number|
      product_key = product_key_for(product_name)

      if product_key.nil?
        if ignored_match?(product_name)
          ignored_product << row(email, product_name, order_date, order_number)
        else
          unrecognized_product << row(email, product_name, order_date, order_number)
        end
        next
      end

      unless quantity_explicit?(product_name, product_key)
        ambiguous_quantity << row(email, product_name, order_date, order_number, product_key: product_key)
      end

      bottle_count = BottleExtractor.call(product_name, product_key)
      if CrmRepurchaseCycleConfig.interpolate(medians_for(product_key), bottle_count).nil?
        orders_missing_cycle_config << row(email, product_name, order_date, order_number, product_key: product_key, bottle_count: bottle_count)
      end
    end

    {
      window_days:                   LOOKBACK_DAYS,
      unrecognized_product:          summarize(unrecognized_product),
      ignored_product:               summarize(ignored_product),
      ambiguous_quantity:            summarize(ambiguous_quantity),
      orders_missing_cycle_config:   summarize(orders_missing_cycle_config),
      products_missing_cycle_config: products_missing_cycle_config
    }
  end

  private

  # 產品層級：不看訂單，直接看 13 個追蹤產品裡誰完全沒有 config 列。
  def products_missing_cycle_config
    configured_keys = CrmRepurchaseCycleConfig.distinct.pluck(:product_key)

    tracked_products
      .reject { |key, _label| configured_keys.include?(key) }
      .map { |key, label| { product_key: key, label: label } }
  end

  def tracked_products
    @tracked_products ||= CrmProduct.confirmed
      .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
      .order(:id).pluck(:key, :label)
  end

  def medians_for(product_key)
    @medians_cache ||= {}
    @medians_cache[product_key] ||= CrmRepurchaseCycleConfig.medians_for(product_key)
  end

  def fetch_orders
    since_date = Date.current - LOOKBACK_DAYS
    ShoplineOrder.valid_paid
      .where("order_date >= ?", since_date.beginning_of_day)
      .pluck(:email, :product_name, :order_date, :order_number)
  end

  # sql_pattern 的 LIKE 子字串 + CrmProductAlias 已知別名（見 CrmProduct#matching_substrings）。
  def matchers
    @matchers ||= begin
      tracked_keys = tracked_products.map(&:first)
      substrings_by_key = CrmProduct.substring_matchers(keys: tracked_keys)
      regex_by_key = CrmProduct.confirmed.where(key: tracked_keys).pluck(:key, :regex_pattern).to_h

      tracked_keys.each_with_object({}) do |key, h|
        h[key] = { substrings: substrings_by_key[key] || [], regex: safe_regex(regex_by_key[key]) }
      end
    end
  end

  # 明確不追蹤商品：mask 等 confirmed 但排除在 13 個追蹤產品外的 CrmProduct，
  # 或 KNOWN_UNTRACKED_KEYWORDS 登記的品名——沿用既有 Registry/排除清單，
  # 不建立第二套獨立的商品判斷規則。
  def ignored_match?(product_name)
    excluded_matchers.any? { |_key, substrings| substrings.any? { |s| product_name.include?(s) } } ||
      KNOWN_UNTRACKED_KEYWORDS.any? { |kw| product_name.include?(kw) }
  end

  def excluded_matchers
    @excluded_matchers ||= CrmProduct.substring_matchers(keys: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
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
