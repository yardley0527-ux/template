class OmnipotentRestockController < ApplicationController
  OMNIPOTENT      = "product_name LIKE '%全能%'"
  LOYAL_THRESHOLD = 2

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  # 實際回購中位數（天），由 DB 統計得出
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

  def export
    rows = @overdue + @restock_soon
    send_data "\xEF\xBB\xBF" + restock_csv(rows),
              filename: "全能補貨名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_loyal
    send_data "\xEF\xBB\xBF" + loyal_csv,
              filename: "全能常購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_restock_data
    today       = Date.today
    since_date  = today - 365  # 只追蹤近一年內有購買的客戶

    # 每位客戶最近一次全能購買
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

    return (@restock_list = @overdue = @restock_soon = @not_urgent = []) if last_order_by_email.empty?

    @event_label = "近一年全客戶追蹤"

    # 建立直播期間範圍集合，用來標記哪些購買來自直播
    broadcast_ranges = OmnipotentAnalysisController::OMNI_EVENTS.map do |e|
      e[:date].beginning_of_day..(e[:date] + 3).end_of_day
    end

    customers = ShoplineCustomer
      .where(email: last_order_by_email.keys)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @restock_list = customers.map do |c|
      order                = last_order_by_email[c.email]
      bottles              = extract_bottles(order[:product_name])
      expected_return_date = order[:order_date] + expected_days(bottles)
      days_left            = (expected_return_date - today).to_i
      bought_dt            = order[:order_date].to_time
      from_broadcast       = broadcast_ranges.any? { |r| r.cover?(bought_dt) }

      {
        customer:             c,
        product_name:         order[:product_name],
        bought_date:          order[:order_date],
        bottles:              bottles,
        expected_return_date: expected_return_date,
        days_left:            days_left,
        from_broadcast:       from_broadcast
      }
    end.sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    @overdue      = @restock_list.select { |r| r[:days_left] <= 0 }
    @restock_soon = @restock_list.select { |r| r[:days_left].between?(1, 14) }
    @not_urgent   = @restock_list.select { |r| r[:days_left] > 14 }
  end

  # 常購名單：不管目前是否該補貨，每場直播前都該邀請的全能老客戶
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

  # 依瓶數查實際回購中位數；無精確值時線性內插
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

  def restock_csv(rows = @restock_list)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["狀態", "姓名", "卡別", "IG", "上次購買", "瓶數", "預計回購日", "距今天數"]
      rows.each do |r|
        status = r[:days_left] <= 0 ? "逾期未回購" : r[:days_left] <= 14 ? "即將回購" : "尚早"
        csv << row_data(status, r)
      end
    end
  end

  def row_data(status, r)
    c = r[:customer]
    ig = c.instagram_account&.gsub('@', '')&.strip
    [status, c.full_name, c.membership_level, ig,
     r[:bought_date]&.strftime("%Y/%m/%d"),
     r[:bottles], r[:expected_return_date]&.strftime("%Y/%m/%d"), r[:days_left]]
  end

  def loyal_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "IG", "全能購買次數", "全能累計消費(NT$)", "上次購買", "下一步"]
      @loyal_buyers.each do |r|
        c = r[:customer]
        csv << [c.full_name, c.membership_level, c.mobile_phone, c.instagram_account,
                 r[:order_count], r[:total_spend].to_i, r[:last_date]&.strftime("%Y/%m/%d"), r[:next_action]]
      end
    end
  end
end
