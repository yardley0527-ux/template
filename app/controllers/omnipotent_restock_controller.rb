class OmnipotentRestockController < ApplicationController
  OMNIPOTENT           = "product_name LIKE '%全能%'"
  LOYAL_THRESHOLD      = 2
  REMINDER_BUFFER_DAYS = 7
  CHURN_THRESHOLD_DAYS = -60

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  # 客戶價值分級（依累計瓶數 + 購買次數）
  CUSTOMER_TYPES = [
    { key: :vip,       label: "VIP常購客", emoji: "🔵", color: "#1d4ed8", rank: 4,
      desc: "2次以上且累計 6 瓶以上" },
    { key: :big,       label: "大套組客",  emoji: "🟠", color: "#ea580c", rank: 3,
      desc: "累計 6 瓶以上" },
    { key: :small,     label: "小套組客",  emoji: "🟡", color: "#ca8a04", rank: 2,
      desc: "累計 3–5 瓶" },
    { key: :single,    label: "單瓶客",    emoji: "🟢", color: "#6b7280", rank: 1,
      desc: "累計 1–2 瓶" }
  ].freeze

  # 實際回購中位數（天），DB 統計 5,082 筆
  REPURCHASE_MEDIANS = {
    1 => 45, 2 => 50, 3 => 60, 4 => 67,
    6 => 89, 10 => 106, 12 => 120
  }.freeze

  # CRM 優先分數權重（客服不用思考，直接看分數排序）
  CRM_SCORE = {
    type:            { vip: 40, big: 20, small: 10, single: 0 },
    from_broadcast:  10,   # 直播購買
    repeat_buyer:    20,   # 有回購歷史（omni_count > 1）
    overdue_mild:    10,   # 逾期 31–60 天
    overdue_severe:  20    # 逾期 60 天以上
  }.freeze

  before_action :build_restock_data, only: [:index, :export, :export_at_risk]
  before_action :build_loyal_buyers,  only: [:index, :export_loyal]

  def index; end

  def export
    rows = @today  # already sorted by CRM score
    send_data "\xEF\xBB\xBF" + restock_csv(rows),
              filename: "全能維護名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_at_risk
    send_data "\xEF\xBB\xBF" + restock_csv(@at_risk),
              filename: "全能流失喚醒名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_loyal
    send_data "\xEF\xBB\xBF" + loyal_csv,
              filename: "全能常購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def update_status
    ns = OmnipotentNotificationStatus.find_or_initialize_by(
      email:          params[:email],
      reference_date: params[:reference_date]
    )
    ns.status     = params[:status]
    ns.notified_at = Time.current if params[:status] == "已通知" && ns.notified_at.nil?
    ns.save!
    render json: { success: true, status: ns.status }
  rescue => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
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

    all_emails = last_order_by_email.keys

    # 各 email 全能歷史購買次數（不限一年）
    omni_counts = ShoplineOrder.where(OMNIPOTENT).where(email: all_emails).group(:email).count

    # 各 email 全能歷史累計瓶數（不限一年）
    bottle_totals = Hash.new(0)
    ShoplineOrder.where(OMNIPOTENT).where(email: all_emails).pluck(:email, :product_name).each do |email, pn|
      bottle_totals[email] += extract_bottles(pn)
    end

    # 通知狀態（以 [email, reference_date] 為 key）
    notif_map = {}
    OmnipotentNotificationStatus.where(email: all_emails).each do |n|
      notif_map[[n.email, n.reference_date]] = n
    end

    customers = ShoplineCustomer
      .where(email: all_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @restock_list = customers.map do |c|
      order  = last_order_by_email[c.email]
      bought = order[:order_date]
      bottles = extract_bottles(order[:product_name])

      estimated_finish_date    = bought + bottles * 30
      expected_return_date     = bought + expected_days(bottles)
      suggested_reminder_date  = expected_return_date - REMINDER_BUFFER_DAYS
      days_left                = (expected_return_date   - today).to_i
      days_until_reminder      = (suggested_reminder_date - today).to_i
      count                    = omni_counts[c.email]   || 0
      total_bottles            = bottle_totals[c.email] || 0

      {
        customer:                c,
        product_name:            order[:product_name],
        bought_date:             bought,
        bottles:                 bottles,
        estimated_finish_date:   estimated_finish_date,
        expected_return_date:    expected_return_date,
        suggested_reminder_date: suggested_reminder_date,
        days_left:               days_left,
        days_until_reminder:     days_until_reminder,
        source_event:            source_event_label(bought),
        omni_count:              count,
        total_omni_bottles:      total_bottles,
        customer_type:           resolve_customer_type(count, total_bottles),
        notification:            notif_map[[c.email, bought]]
      }
    end.tap do |list|
      list.each { |r| r[:crm_score] = calc_crm_score(r) }
    end.sort_by { |r| [-r[:crm_score], r[:days_left]] }

    @remind_now = @restock_list.select { |r| r[:days_until_reminder] <= 0 && r[:days_left] > 0 }
    @overdue    = @restock_list.select { |r| r[:days_left] < 0 && r[:days_left] >= CHURN_THRESHOLD_DAYS }
    @at_risk    = @restock_list.select { |r| r[:days_left] < CHURN_THRESHOLD_DAYS }
    @not_urgent = @restock_list.select { |r| r[:days_until_reminder] > 0 }

    # 今日應聯絡 = 提醒中 + 逾期未回購，統一依 CRM Score 排序
    @today            = (@remind_now + @overdue).sort_by { |r| -r[:crm_score] }
    @high_value_count = @today.count { |r| [:vip, :big].include?(r[:customer_type][:key]) }
  end

  def build_loyal_buyers
    order_counts = ShoplineOrder.where(OMNIPOTENT).where.not(email: [nil, ""]).group(:email).count
    loyal_emails = order_counts.select { |_, n| n >= LOYAL_THRESHOLD }.keys
    return (@loyal_buyers = []) if loyal_emails.empty?

    bottle_totals = Hash.new(0)
    ShoplineOrder.where(OMNIPOTENT).where(email: loyal_emails).pluck(:email, :product_name).each do |email, pn|
      bottle_totals[email] += extract_bottles(pn)
    end

    last_dates = {}
    ShoplineOrder.where(OMNIPOTENT).where(email: loyal_emails)
      .order(:email, order_date: :desc).pluck(:email, :order_date)
      .each { |email, date| last_dates[email] ||= date&.to_date }

    amounts = Hash.new(0.0)
    ShoplineOrder.where(OMNIPOTENT).where(email: loyal_emails)
      .group(:email, :order_number)
      .pluck(:email,
             Arel.sql("MAX(NULLIF(total_amount, 0))"),
             Arel.sql("SUM(COALESCE(checkout_amount, 0))"))
      .each { |email, max_total, sum_checkout| amounts[email] += (max_total || sum_checkout).to_f }

    customers = ShoplineCustomer
      .where(email: loyal_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)

    @loyal_buyers = customers.map do |c|
      count         = order_counts[c.email]   || 0
      total_bottles = bottle_totals[c.email]  || 0
      {
        customer:      c,
        order_count:   count,
        total_spend:   amounts[c.email] || 0,
        last_date:     last_dates[c.email],
        total_bottles: total_bottles,
        customer_type: resolve_customer_type(count, total_bottles)
      }
    end.sort_by { |r| [-r[:customer_type][:rank], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:order_count], -r[:total_spend]] }
  end

  # ── Helpers ────────────────────────────────────────────────────────

  def calc_crm_score(row)
    score  = CRM_SCORE[:type][row[:customer_type][:key]] || 0
    score += CRM_SCORE[:from_broadcast]  if row[:source_event] != "一般購買"
    score += CRM_SCORE[:repeat_buyer]    if row[:omni_count] > 1
    dl = row[:days_left]
    score += if dl < -60 then CRM_SCORE[:overdue_severe]
              elsif dl < -30 then CRM_SCORE[:overdue_mild]
              else 0 end
    score
  end

  def resolve_customer_type(order_count, total_bottles)
    if order_count >= 2 && total_bottles >= 6
      CUSTOMER_TYPES.find { |t| t[:key] == :vip }
    elsif total_bottles >= 6
      CUSTOMER_TYPES.find { |t| t[:key] == :big }
    elsif total_bottles >= 3
      CUSTOMER_TYPES.find { |t| t[:key] == :small }
    else
      CUSTOMER_TYPES.find { |t| t[:key] == :single }
    end
  end

  def source_event_label(bought_date)
    event = OmnipotentAnalysisController::OMNI_EVENTS.find do |e|
      (e[:date]..(e[:date] + 3)).cover?(bought_date)
    end
    event ? "#{event[:year]}/#{event[:label]}" : "一般購買"
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

  def restock_csv(rows)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["狀態", "客戶類型", "姓名", "卡別", "IG", "來源場次",
              "上次購買", "瓶數", "累計瓶數", "全能累計次數",
              "吃完日", "建議提醒日", "預計回購日", "距今天數", "通知狀態"]
      rows.each do |r|
        c  = r[:customer]
        ig = c.instagram_account&.gsub('@', '')&.strip
        seg = if r[:days_left] < CHURN_THRESHOLD_DAYS then "可能流失"
               elsif r[:days_left] < 0 then "逾期未回購"
               elsif r[:days_until_reminder] <= 0 then "提醒中"
               else "尚早" end
        csv << [
          seg, r[:customer_type][:label], c.full_name, c.membership_level, ig,
          r[:source_event],
          r[:bought_date]&.strftime("%Y/%m/%d"), r[:bottles], r[:total_omni_bottles], r[:omni_count],
          r[:estimated_finish_date]&.strftime("%Y/%m/%d"),
          r[:suggested_reminder_date]&.strftime("%Y/%m/%d"),
          r[:expected_return_date]&.strftime("%Y/%m/%d"),
          r[:days_left],
          r[:notification]&.status || "未通知"
        ]
      end
    end
  end

  def loyal_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["客戶類型", "姓名", "卡別", "IG", "全能購買次數", "累計瓶數", "全能累計消費(NT$)", "上次購買"]
      @loyal_buyers.each do |r|
        c  = r[:customer]
        ig = c.instagram_account&.gsub('@', '')&.strip
        csv << [r[:customer_type][:label], c.full_name, c.membership_level, ig,
                r[:order_count], r[:total_bottles], r[:total_spend].to_i,
                r[:last_date]&.strftime("%Y/%m/%d")]
      end
    end
  end
end
