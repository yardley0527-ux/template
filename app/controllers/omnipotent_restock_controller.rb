class OmnipotentRestockController < ApplicationController
  OMNIPOTENT     = "product_name LIKE '%全能%'"
  DAYS_PER_BOTTLE = 30

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  before_action :build_restock_data

  def index; end

  def export
    rows = case params[:scope]
           when "soon"    then @restock_soon
           when "overdue" then @overdue
           else                @restock_list
           end
    label = case params[:scope]
            when "soon"    then "即將用完"
            when "overdue" then "逾期"
            else                "全部"
            end
    send_data "\xEF\xBB\xBF" + restock_csv(rows),
              filename: "全能補貨提醒_#{label}_#{Date.today}.csv",
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
        customer:      c,
        product_name:  order[:product_name],
        bought_date:   order[:order_date],
        bottles:       bottles,
        runout_date:   runout_date,
        days_left:     days_left
      }
    end.sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    @overdue      = @restock_list.select { |r| r[:days_left] < 0 }
    @restock_soon = @restock_list.select { |r| r[:days_left].between?(0, 30) }
    @not_urgent   = @restock_list.select { |r| r[:days_left] > 30 }
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(/全能(\d+)/)
    m ? m[1].to_i : 1
  end

  def restock_csv(rows = @restock_list)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["優先度", "姓名", "卡別", "電話", "IG", "上次購買", "瓶數", "預估用完日", "剩餘天數"]
      rows.each do |r|
        priority = r[:days_left] < 0 ? "急需補貨" : r[:days_left] <= 30 ? "即將用完" : "暫不急"
        csv << row_data(priority, r)
      end
    end
  end

  def row_data(priority, r)
    c = r[:customer]
    [priority, c.full_name, c.membership_level, c.mobile_phone,
     c.instagram_account, r[:bought_date]&.strftime("%Y/%m/%d"),
     r[:bottles], r[:runout_date]&.strftime("%Y/%m/%d"), r[:days_left]]
  end
end
