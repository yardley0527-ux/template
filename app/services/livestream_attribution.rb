# frozen_string_literal: true

# 方案 B PR2：單場直播的訂單歸因查詢——統一取代散落在各 controller/concern
# 的 event_range 計算，成為「推定檔期」數字的唯一來源。
#
# 歸因規則（不得變動，UI 必須標示為推定）：
#   固定 Asia/Taipei 時區，半開區間：
#     order_time >= 場次日 00:00（Asia/Taipei）
#     order_time <  (場次日 + window_days + 1) 00:00（Asia/Taipei）
#   不使用 23:59:59 上界寫法，避免微秒級誤差。
#
# 訂單以 order_number 去重，金額走 ShoplineOrder::TOTAL_SQL（MAX(NULLIF(total_amount,0))，
# 全為 0 則 fallback SUM(checkout_amount)）——與該 model 既有定義同一份 SQL 片段，
# 不另外手刻一套算法。
#
# buyers / new_buyers 只計 email 非空的訂單；orders / revenue 涵蓋全部訂單
# （含 email 空白），並透過 unidentified_orders 揭露未識別比例。
#
# 這是唯讀查詢物件，不修改任何 ShoplineOrder 資料。
class LivestreamAttribution
  TAIPEI_ZONE = "Asia/Taipei"
  DEFAULT_WINDOW_DAYS = 3
  DEFAULT_COMPARISON_WINDOWS = [0, 1, 3, 7].freeze

  def self.window_range(date, window_days = DEFAULT_WINDOW_DAYS)
    zone  = ActiveSupport::TimeZone[TAIPEI_ZONE]
    start = zone.local(date.year, date.month, date.day)
    finish = start + (window_days.to_i + 1).days
    start...finish
  end

  def self.window_comparison(livestream, windows: DEFAULT_COMPARISON_WINDOWS)
    windows.map do |w|
      attribution = new(livestream, window_days: w)
      {
        window_days: w,
        orders: attribution.orders,
        revenue: attribution.revenue,
        buyers: attribution.buyers,
        new_buyers: attribution.new_buyers,
        unidentified_orders: attribution.unidentified_orders
      }
    end
  end

  def initialize(livestream, window_days: nil)
    @livestream  = livestream
    @window_days = (window_days || livestream.window_days || DEFAULT_WINDOW_DAYS).to_i
  end

  attr_reader :livestream, :window_days

  def window_range
    self.class.window_range(livestream.date, window_days)
  end

  # 每筆去重後的訂單：{ order_number:, email:, date: (Date), amount: (BigDecimal) }
  def order_rows
    @order_rows ||= grouped_rows(ShoplineOrder.where(order_date: window_range))
  end

  def orders
    order_rows.size
  end

  def revenue
    order_rows.sum { |r| r[:amount] }
  end

  def buyers
    identified_emails.size
  end

  def new_buyers
    emails = identified_emails
    return 0 if emails.empty?

    first_order_dates = ShoplineOrder.where(email: emails).group(:email).minimum(:order_date)
    event_date = livestream.date
    emails.count do |email|
      first = first_order_dates[email]
      first && first.to_date >= event_date
    end
  end

  def unidentified_orders
    order_rows.count { |r| r[:email].blank? }
  end

  def unidentified_orders_pct
    return 0.0 if orders.zero?

    (unidentified_orders.to_f / orders * 100).round(1)
  end

  # D0..D+window_days 每日拆解（window_days+1 筆）
  def daily_breakdown
    (0..window_days).map do |offset|
      day  = livestream.date + offset
      rows = order_rows.select { |r| r[:date] == day }
      {
        date: day,
        offset: offset,
        orders: rows.size,
        revenue: rows.sum { |r| r[:amount] },
        buyers: rows.filter_map { |r| r[:email] }.uniq.size
      }
    end
  end

  # 各產品在本場窗內的訂單/營收/買家（走 ProductNameResolver，含 bundle component）。
  # 注意：組合商品的訂單會同時計入多個 product_key（沿用既有產品分析頁慣例，
  # 非本服務新增行為），營收未依成分拆分。
  def product_rows(product_keys: livestream.product_keys)
    Array(product_keys).filter_map do |key|
      scope = ProductNameResolver.orders_for(key).where(order_date: window_range)
      lines = grouped_rows(scope)
      next nil if lines.empty?

      {
        product_key: key,
        orders: lines.size,
        revenue: lines.sum { |r| r[:amount] },
        buyers: lines.filter_map { |r| r[:email] }.uniq.size
      }
    end
  end

  # 與其他場次窗口重疊、共享的訂單（同一張訂單落入兩場直播）。
  # 只回傳 order_number 與對方場次資訊，不含個資。
  def overlapping_orders
    my_numbers = order_numbers_in(window_range)
    return { total_shared_orders: 0, with: [] } if my_numbers.empty?

    my_range = window_range
    candidates = Livestream.where.not(id: livestream.id).pluck(:id, :date, :window_days)

    overlaps = candidates.filter_map do |other_id, other_date, other_window_days|
      other_range = self.class.window_range(other_date, other_window_days || DEFAULT_WINDOW_DAYS)
      next nil unless my_range.begin < other_range.end && other_range.begin < my_range.end

      shared = my_numbers & order_numbers_in(other_range)
      next nil if shared.empty?

      { livestream_id: other_id, date: other_date, shared_order_count: shared.size }
    end

    { total_shared_orders: overlaps.sum { |o| o[:shared_order_count] }, with: overlaps }
  end

  private

  def identified_emails
    @identified_emails ||= order_rows.filter_map { |r| r[:email] }.uniq
  end

  def order_numbers_in(range)
    ShoplineOrder.where(order_date: range).where.not(order_number: [nil, ""])
                 .distinct.pluck(:order_number).to_set
  end

  # scope 需已限制 order_date 範圍；依 order_number 分組，金額用
  # ShoplineOrder::TOTAL_SQL（與該 model 定義同一份口徑）。
  def grouped_rows(scope)
    scope.where.not(shopline_orders: { order_number: [nil, ""] })
         .group("shopline_orders.order_number")
         .pluck(
           Arel.sql("shopline_orders.order_number"),
           Arel.sql("MIN(shopline_orders.email) AS email"),
           Arel.sql("MIN(shopline_orders.order_date) AS order_date"),
           Arel.sql("(#{ShoplineOrder::TOTAL_SQL}) AS amount")
         )
         .map do |order_number, email, date, amount|
      { order_number: order_number, email: email.presence, date: date&.to_date, amount: amount.to_d }
    end
  end
end
