# frozen_string_literal: true

# 從歷史有效訂單（ShoplineOrder.valid_paid，已排除退款/取消/未付款/欄位缺漏）
# 算出一個產品「依購買瓶數分桶」的回購間隔天數中位數，供
# CrmRepurchaseCycleConfigSeedService 寫入 CrmRepurchaseCycleConfig。
#
# 桶（bucket）用「這次購買的瓶數」分類，量測到下一筆同產品購買的間隔天數——
# 跟既有 JourneyProducts::PRODUCTS[:medians] 的語意完全一致（買 N 瓶預期
# medians[N] 天後回購）。樣本數不足的桶不回傳，交由呼叫端（seed
# service／資料品質報告）判斷是否要略過該瓶數,不會用單筆資料硬湊出一個
# 看起來精確、實際上不可靠的天數。
class RepurchaseCycleMedianCalculator
  MIN_SAMPLE_SIZE = 5
  WINDOW_DAYS     = 730 # 2 年內的訂單，避免用過舊、可能已不具代表性的資料

  def self.call(product_key:)
    new(product_key: product_key).call
  end

  def initialize(product_key:)
    @product_key = product_key
    @crm_product = CrmProduct.find_by(key: product_key, status: "confirmed")
  end

  # => { bottle_count => { median_days:, sample_size: } }
  def call
    return {} unless @crm_product&.sql_pattern.present?

    orders = fetch_orders
    return {} if orders.empty?

    intervals_by_bucket = Hash.new { |h, k| h[k] = [] }

    orders.group_by { |o| o[:identity_key] }.each_value do |customer_orders|
      sorted = customer_orders.sort_by { |o| o[:order_date] }
      sorted.each_cons(2) do |current, nxt|
        interval = (nxt[:order_date] - current[:order_date]).to_i
        next if interval <= 0

        bucket = BottleExtractor.call(current[:product_name], @product_key)
        intervals_by_bucket[bucket] << interval
      end
    end

    intervals_by_bucket.each_with_object({}) do |(bucket, intervals), result|
      next if intervals.size < MIN_SAMPLE_SIZE

      result[bucket] = { median_days: median(intervals), sample_size: intervals.size }
    end
  end

  private

  def fetch_orders
    since_date = Date.current - WINDOW_DAYS

    rows = ShoplineOrder.valid_paid
      .where(@crm_product.matching_sql_pattern)
      .where("order_date >= ?", since_date.beginning_of_day)
      .joins(<<~SQL)
        LEFT JOIN shopline_customers sc
          ON LOWER(TRIM(sc.email)) = LOWER(TRIM(shopline_orders.email))
          AND sc.mobile_phone IS NOT NULL
          AND TRIM(sc.mobile_phone) <> ''
      SQL
      .pluck(
        Arel.sql("COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(shopline_orders.email)))"),
        :product_name,
        :order_date
      )

    rows.map { |identity_key, product_name, order_date| { identity_key: identity_key, product_name: product_name, order_date: order_date.to_date } }
  end

  def median(values)
    sorted = values.sort
    len = sorted.length
    mid = len / 2
    len.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
  end
end
