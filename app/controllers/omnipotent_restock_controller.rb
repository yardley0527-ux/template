class OmnipotentRestockController < ApplicationController
  OMNIPOTENT      = "product_name LIKE '%全能%'"
  DAYS_PER_BOTTLE = 30
  LOYAL_THRESHOLD = 2 # 全能歷史購買次數達此門檻，視為常購客，每場直播前都該邀請

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  # 依優先度建議的折扣方案，僅供前台人員發送時參考，不是已建立的系統折扣碼
  SUGGESTED_OFFERS = {
    overdue:      "急需補貨．建議 85 折",
    restock_soon: "即將用完．建議 9 折",
    not_urgent:   "暫不急．建議 95 折",
    loyal:        "常購回饋．建議 9 折"
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
    # 從 OMNI_EVENTS 自動取最近一檔全能場次
    past_omni = OmnipotentAnalysisController::OMNI_EVENTS.select { |e| e[:date] <= Date.today }
    return (@restock_list = @overdue = @restock_soon = @not_urgent = []) if past_omni.empty?

    last_event   = past_omni.last
    @event_date  = last_event[:date]
    @event_label = "#{last_event[:year]}/#{last_event[:label]}"
    event_range  = @event_date.beginning_of_day..(@event_date + 3).end_of_day

    # 上一檔全能購買（每人取最新一筆）
    orders_raw = ShoplineOrder
      .where(OMNIPOTENT)
      .where(order_date: event_range)
      .where.not(email: [nil, ""])
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date.to_date }
    end

    # 排除已回購
    repurchased = ShoplineOrder
      .where(OMNIPOTENT)
      .where("order_date > ?", (@event_date + 3).end_of_day)
      .where.not(email: [nil, ""])
      .distinct.pluck(:email)

    eligible_emails = last_order_by_email.keys - repurchased
    today = Date.today

    customers = ShoplineCustomer
      .where(email: eligible_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @restock_list = customers.map do |c|
      order        = last_order_by_email[c.email]
      bottles      = extract_bottles(order[:product_name])
      runout_date  = order[:order_date] + bottles * DAYS_PER_BOTTLE
      days_left    = (runout_date - today).to_i

      {
        customer:       c,
        product_name:   order[:product_name],
        bought_date:    order[:order_date],
        bottles:        bottles,
        runout_date:    runout_date,
        days_left:      days_left,
        suggested_offer: suggested_offer_for(days_left)
      }
    end.sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    @overdue      = @restock_list.select { |r| r[:days_left] <= 7 }
    @restock_soon = @restock_list.select { |r| r[:days_left].between?(8, 21) }
    @not_urgent   = @restock_list.select { |r| r[:days_left] > 21 }
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
        customer:        c,
        order_count:     order_counts[c.email] || 0,
        total_spend:     amounts[c.email] || 0,
        last_date:       last_dates[c.email],
        suggested_offer: SUGGESTED_OFFERS[:loyal]
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:order_count], -r[:total_spend]] }
  end

  def suggested_offer_for(days_left)
    if days_left <= 7
      SUGGESTED_OFFERS[:overdue]
    elsif days_left <= 21
      SUGGESTED_OFFERS[:restock_soon]
    else
      SUGGESTED_OFFERS[:not_urgent]
    end
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(/全能(\d+)/)
    m ? m[1].to_i : 1
  end

  def restock_csv(rows = @restock_list)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["優先度", "姓名", "卡別", "電話", "IG", "上次購買", "瓶數", "預估用完日", "剩餘天數", "建議方案"]
      rows.each do |r|
        priority = r[:days_left] <= 7 ? "急需補貨" : r[:days_left] <= 21 ? "即將用完" : "暫不急"
        csv << row_data(priority, r)
      end
    end
  end

  def row_data(priority, r)
    c = r[:customer]
    [priority, c.full_name, c.membership_level, c.mobile_phone,
     c.instagram_account, r[:bought_date]&.strftime("%Y/%m/%d"),
     r[:bottles], r[:runout_date]&.strftime("%Y/%m/%d"), r[:days_left], r[:suggested_offer]]
  end

  def loyal_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "IG", "全能購買次數", "全能累計消費(NT$)", "上次購買", "建議方案"]
      @loyal_buyers.each do |r|
        c = r[:customer]
        csv << [c.full_name, c.membership_level, c.mobile_phone, c.instagram_account,
                 r[:order_count], r[:total_spend].to_i, r[:last_date]&.strftime("%Y/%m/%d"), r[:suggested_offer]]
      end
    end
  end
end
