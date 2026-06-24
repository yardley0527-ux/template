class OmnipotentRestockController < ApplicationController
  OMNIPOTENT           = "product_name LIKE '%全能%'"
  LOYAL_THRESHOLD      = 2
  REMINDER_BUFFER_DAYS = 7   # 提醒日 = 預計回購日前幾天
  CHURN_THRESHOLD_DAYS = -60 # 超過預計回購日這麼多天還沒回來 → 可能流失

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  # 實際回購中位數（天），由 DB 統計 5,082 筆回購記錄得出
  REPURCHASE_MEDIANS = {
    1  => 45,
    2  => 50,
    3  => 60,
    4  => 67,
    6  => 89,
    10 => 106,
    12 => 120
  }.freeze

  before_action :build_restock_data
  before_action :build_loyal_buyers

  def index; end

  # 今日提醒 + 逾期未回購
  def export
    rows = @remind_now + @overdue
    send_data "\xEF\xBB\xBF" + restock_csv(rows, "今日維護"),
              filename: "全能維護名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  # 可能流失喚醒名單
  def export_at_risk
    send_data "\xEF\xBB\xBF" + restock_csv(@at_risk, "可能流失"),
              filename: "全能流失喚醒名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_loyal
    send_data "\xEF\xBB\xBF" + loyal_csv,
              filename: "全能常購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_restock_data
    today      = Date.today
    since_date = today - 365

    orders_raw = ShoplineOrder
      .where(OMNIPOTENT)
      .where("order_date >= ?", since_date.beginning_of_day)
      .where.not(email: [nil, ""])
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date.to_date }
    end

    return (@restock_list = @remind_now = @overdue = @at_risk = @not_urgent = []) if last_order_by_email.empty?

    broadcast_ranges = OmnipotentAnalysisController::OMNI_EVENTS.map do |e|
      e[:date].beginning_of_day..(e[:date] + 3).end_of_day
    end

    all_emails  = last_order_by_email.keys
    omni_counts = ShoplineOrder.where(OMNIPOTENT).where(email: all_emails).group(:email).count

    customers = ShoplineCustomer
      .where(email: all_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @restock_list = customers.map do |c|
      order  = last_order_by_email[c.email]
      bought = order[:order_date]
      bottles = extract_bottles(order[:product_name])

      # 喝完日：理論瓶數 × 30 天（顯示用）
      estimated_finish_date   = bought + bottles * 30
      # 預計回購日：由實際回購中位數推算（segmentation 用）
      expected_return_date    = bought + expected_days(bottles)
      # 建議提醒日：預計回購日前 REMINDER_BUFFER_DAYS 天
      suggested_reminder_date = expected_return_date - REMINDER_BUFFER_DAYS

      days_left           = (expected_return_date    - today).to_i
      days_until_reminder = (suggested_reminder_date - today).to_i

      {
        customer:               c,
        product_name:           order[:product_name],
        bought_date:            bought,
        bottles:                bottles,
        estimated_finish_date:  estimated_finish_date,
        expected_return_date:   expected_return_date,
        suggested_reminder_date: suggested_reminder_date,
        days_left:              days_left,
        days_until_reminder:    days_until_reminder,
        from_broadcast:         broadcast_ranges.any? { |r| r.cover?(bought.to_time) },
        omni_count:             omni_counts[c.email] || 0
      }
    end.sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    # 提醒中：建議提醒日已到，但還沒過預計回購日
    @remind_now = @restock_list.select { |r| r[:days_until_reminder] <= 0 && r[:days_left] > 0 }
    # 逾期未回購：過了預計回購日，但還在流失閾值內（0 ~ -60 天）
    @overdue    = @restock_list.select { |r| r[:days_left] < 0 && r[:days_left] >= CHURN_THRESHOLD_DAYS }
    # 可能流失：超過流失閾值（-60 天以上）
    @at_risk    = @restock_list.select { |r| r[:days_left] < CHURN_THRESHOLD_DAYS }
    # 尚早：還沒到建議提醒日
    @not_urgent = @restock_list.select { |r| r[:days_until_reminder] > 0 }
  end

  def build_loyal_buyers
    order_counts = ShoplineOrder
      .where(OMNIPOTENT)
      .where.not(email: [nil, ""])
      .group(:email).count

    loyal_emails = order_counts.select { |_, n| n >= LOYAL_THRESHOLD }.keys
    return (@loyal_buyers = []) if loyal_emails.empty?

    last_dates = {}
    ShoplineOrder.where(OMNIPOTENT).where(email: loyal_emails)
      .order(:email, order_date: :desc)
      .pluck(:email, :order_date)
      .each { |email, date| last_dates[email] ||= date&.to_date }

    amounts = Hash.new(0.0)
    ShoplineOrder.where(OMNIPOTENT).where(email: loyal_emails)
      .group(:email, :order_number)
      .pluck(
        :email,
        Arel.sql("MAX(NULLIF(total_amount, 0)) AS max_total"),
        Arel.sql("SUM(COALESCE(checkout_amount, 0)) AS sum_checkout")
      )
      .each { |email, max_total, sum_checkout| amounts[email] += (max_total || sum_checkout).to_f }

    customers = ShoplineCustomer
      .where(email: loyal_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)

    @loyal_buyers = customers.map do |c|
      {
        customer:    c,
        order_count: order_counts[c.email] || 0,
        total_spend: amounts[c.email] || 0,
        last_date:   last_dates[c.email]
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:order_count], -r[:total_spend]] }
  end

  def expected_days(bottles)
    return REPURCHASE_MEDIANS[bottles] if REPURCHASE_MEDIANS.key?(bottles)
    keys = REPURCHASE_MEDIANS.keys.sort
    lo = keys.select { |k| k < bottles }.last
    hi = keys.select { |k| k > bottles }.first
    return REPURCHASE_MEDIANS[lo || hi] unless lo && hi
    lo_v = REPURCHASE_MEDIANS[lo]; hi_v = REPURCHASE_MEDIANS[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(/全能(\d+)/)
    m ? m[1].to_i : 1
  end

  def restock_csv(rows, status_label)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["狀態", "姓名", "卡別", "IG", "購買來源", "上次購買", "瓶數",
              "喝完日", "建議提醒日", "預計回購日", "距今天數", "全能累計次數"]
      rows.each do |r|
        c  = r[:customer]
        ig = c.instagram_account&.gsub('@', '')&.strip
        source = r[:from_broadcast] ? "直播購買" : "一般購買"
        csv << [
          status_label,
          c.full_name, c.membership_level, ig, source,
          r[:bought_date]&.strftime("%Y/%m/%d"),
          r[:bottles],
          r[:estimated_finish_date]&.strftime("%Y/%m/%d"),
          r[:suggested_reminder_date]&.strftime("%Y/%m/%d"),
          r[:expected_return_date]&.strftime("%Y/%m/%d"),
          r[:days_left],
          r[:omni_count]
        ]
      end
    end
  end

  def loyal_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "IG", "全能購買次數", "全能累計消費(NT$)", "上次購買"]
      @loyal_buyers.each do |r|
        c  = r[:customer]
        ig = c.instagram_account&.gsub('@', '')&.strip
        csv << [c.full_name, c.membership_level, ig,
                r[:order_count], r[:total_spend].to_i, r[:last_date]&.strftime("%Y/%m/%d")]
      end
    end
  end
end
