class OmnipotentRestockController < ApplicationController
  include JourneyProducts

  LOYAL_THRESHOLD      = 2
  REMINDER_BUFFER_DAYS = 7
  CHURN_THRESHOLD_DAYS = -60

  MEMBERSHIP_RANK = {
    "黑卡"    => 5, "金卡" => 4, "銀卡" => 3, "白卡" => 2, "一般會員" => 1
  }.freeze

  CUSTOMER_TYPES = [
    { key: :vip,    label: "VIP常購客", emoji: "🔵", color: "#1d4ed8", rank: 4, desc: "2次以上且累計 6 瓶以上" },
    { key: :big,    label: "大套組客",  emoji: "🟠", color: "#ea580c", rank: 3, desc: "累計 6 瓶以上" },
    { key: :small,  label: "小套組客",  emoji: "🟡", color: "#ca8a04", rank: 2, desc: "累計 3–5 瓶" },
    { key: :single, label: "單瓶客",    emoji: "🟢", color: "#6b7280", rank: 1, desc: "累計 1–2 瓶" }
  ].freeze

  CRM_SCORE = {
    type:           { vip: 40, big: 20, small: 10, single: 0 },
    from_broadcast: 10,
    repeat_buyer:   20,
    overdue_mild:   10,
    overdue_severe: 20
  }.freeze

  ATTRIBUTION_WINDOW = 45

  before_action :set_product
  before_action :build_restock_data, only: [:index, :export, :export_at_risk, :broadcast_room]
  before_action :build_loyal_buyers,  only: [:index, :export_loyal, :broadcast_room]

  # ── Main actions ──────────────────────────────────────────────────

  def index; end

  def broadcast_room
    @rescue_worthy = @at_risk.select { |r| r[:omni_count] >= 2 }
  end

  def boss_dashboard
    build_restock_data
    @month_start      = Date.today.beginning_of_month
    @month_new_buyers = ShoplineOrder.where(@product[:sql])
      .where("order_date >= ?", @month_start).distinct.count(:email)
    month_ns          = OmnipotentNotificationStatus
      .where(product_key: @product_key, notified_at: @month_start..)
    @month_notified   = month_ns.where.not(status: "未通知").count
    @month_replied    = month_ns.where(status: "已回覆").count
    @month_ordered    = OmnipotentNotificationStatus
      .where(product_key: @product_key)
      .where("contacted_at >= ?", @month_start).where(result: "已訂購").count
    @monthly_trend    = 5.downto(0).map do |i|
      m  = Date.today << i
      ms = m.beginning_of_month; me = m.end_of_month
      ns = OmnipotentNotificationStatus.where(product_key: @product_key, notified_at: ms..me)
      { label: m.strftime("%m月"), notified: ns.count,
        ordered: OmnipotentNotificationStatus
          .where(product_key: @product_key, contacted_at: ms..me, result: "已訂購").count }
    end
  end

  def customer_journey
    @customer    = ShoplineCustomer.find(params[:id])
    @omni_orders = ShoplineOrder.where(@product[:sql]).where(email: @customer.email)
      .order(order_date: :desc)
      .pluck(:product_name, :order_date, :order_number)
      .map { |pn, od, on_| { product_name: pn, order_date: od&.to_date, order_number: on_,
                              bottles: extract_bottles(pn), source_event: source_event_label(od&.to_date) } }
    @contact_history = OmnipotentNotificationStatus
      .where(email: @customer.email, product_key: @product_key).order(reference_date: :desc)
    if @omni_orders.any?
      latest = @omni_orders.first
      b = latest[:bottles]; bought = latest[:order_date]; exp = expected_days(b)
      @journey = {
        bought_date:             bought,             bottles:      b,
        product_name:            latest[:product_name],
        source_event:            latest[:source_event],
        estimated_finish_date:   bought + b * 30,
        expected_return_date:    bought + exp,
        suggested_reminder_date: bought + exp - REMINDER_BUFFER_DAYS,
        days_left:               (bought + exp - Date.today).to_i,
        days_until_reminder:     (bought + exp - REMINDER_BUFFER_DAYS - Date.today).to_i
      }
      tb = @omni_orders.sum { |o| o[:bottles] }
      @customer_type      = resolve_customer_type(@omni_orders.size, tb)
      @total_omni_bottles = tb
      @omni_count         = @omni_orders.size
    end
  end

  # ── Analytics ─────────────────────────────────────────────────────

  def roi_dashboard
    @total_notified = OmnipotentNotificationStatus
      .where(product_key: @product_key).where.not(status: "未通知").count
    @total_replied  = OmnipotentNotificationStatus
      .where(product_key: @product_key, status: "已回覆").count

    notif_rows = OmnipotentNotificationStatus
      .where(product_key: @product_key).where.not(contacted_at: nil)
      .pluck(:email, :contacted_at)

    all_emails = notif_rows.map(&:first).uniq
    orders_by_email = Hash.new { |h, k| h[k] = [] }
    ShoplineOrder.where(@product[:sql]).where(email: all_emails)
      .order(:email, :order_date)
      .pluck(:email, :order_date, :order_number)
      .each { |em, od, on_| orders_by_email[em] << { date: od.to_date, order_number: on_ } }

    @attributed = []
    notif_rows.each do |email, contacted_at|
      cutoff = contacted_at.to_date
      subsequent = orders_by_email[email].select { |o| o[:date] > cutoff && o[:date] <= cutoff + ATTRIBUTION_WINDOW }
      next if subsequent.empty?
      order_nums = subsequent.map { |o| o[:order_number] }.uniq.compact
      @attributed << { email: email, contacted_at: cutoff, return_date: subsequent.first[:date], order_numbers: order_nums }
    end

    all_order_nums = @attributed.flat_map { |a| a[:order_numbers] }.uniq
    revenue_by_order = {}
    if all_order_nums.any?
      ShoplineOrder.where(order_number: all_order_nums)
        .group(:order_number)
        .pluck(:order_number, Arel.sql("COALESCE(MAX(NULLIF(total_amount,0)), SUM(COALESCE(checkout_amount,0)))"))
        .each { |on_, rev| revenue_by_order[on_] = rev.to_f }
    end
    @attributed.each { |a| a[:revenue] = a[:order_numbers].sum { |on_| revenue_by_order[on_] || 0 }.round }

    @total_attributed   = @attributed.size
    @attributed_revenue = @attributed.sum { |a| a[:revenue] }
    @conversion_rate    = @total_notified > 0 ? (@total_attributed.to_f / @total_notified * 100).round(1) : 0

    @monthly_roi = 5.downto(0).map do |i|
      m = Date.today << i; ms = m.beginning_of_month; me = m.end_of_month
      mn = OmnipotentNotificationStatus
        .where(product_key: @product_key, notified_at: ms..me).where.not(status: "未通知").count
      ma = @attributed.select { |a| a[:contacted_at] >= ms && a[:contacted_at] <= me }
      { label: m.strftime("%m月"), notified: mn, attributed: ma.size,
        revenue: ma.sum { |a| a[:revenue] } }
    end
  end

  def journey_accuracy
    tracked_pairs = OmnipotentNotificationStatus
      .where(product_key: @product_key)
      .select(:email, :reference_date).distinct
      .map { |n| [n.email, n.reference_date] }.uniq
    emails = tracked_pairs.map(&:first).uniq

    pn_by_key = {}
    orders_by_email = Hash.new { |h, k| h[k] = [] }
    ShoplineOrder.where(@product[:sql]).where(email: emails)
      .order(:email, :order_date)
      .pluck(:email, :product_name, :order_date)
      .each do |em, pn, od|
        date = od.to_date
        pn_by_key[[em, date]] ||= pn
        orders_by_email[em] << date
      end

    @validations = tracked_pairs.map do |email, ref_date|
      pn = pn_by_key[[email, ref_date]]
      next unless pn
      bottles   = extract_bottles(pn)
      predicted = ref_date + expected_days(bottles)
      actual    = orders_by_email[email].sort.find { |d| d > ref_date }
      error     = actual ? (actual - predicted).to_i : nil
      { email: email, reference_date: ref_date, bottles: bottles,
        predicted_return: predicted, actual_return: actual,
        error_days: error, accurate: error ? error.abs <= 14 : nil }
    end.compact.sort_by { |v| -v[:reference_date].to_time.to_i }

    returned      = @validations.select { |v| v[:actual_return] }
    @total_tracked    = @validations.size
    @total_returned   = returned.size
    @return_rate      = @total_tracked > 0 ? (@total_returned.to_f / @total_tracked * 100).round(1) : 0
    @avg_error        = returned.any? ? (returned.sum { |v| v[:error_days] }.to_f / returned.size).round(1) : nil
    @within_14_days   = returned.count { |v| v[:accurate] }
    @accuracy_rate    = returned.any? ? (@within_14_days.to_f / returned.size * 100).round(1) : 0
    @avg_error_abs    = returned.any? ? (returned.sum { |v| v[:error_days].abs }.to_f / returned.size).round(1) : nil

    buckets = { "提早14天+" => 0, "提早7-13天" => 0, "準確(±7天)" => 0, "晚7-13天" => 0, "晚14天+" => 0 }
    returned.each do |v|
      e = v[:error_days]
      if e <= -14 then buckets["提早14天+"] += 1
      elsif e <= -7  then buckets["提早7-13天"] += 1
      elsif e <= 7   then buckets["準確(±7天)"] += 1
      elsif e <= 13  then buckets["晚7-13天"] += 1
      else buckets["晚14天+"] += 1 end
    end
    @error_buckets = buckets
  end

  def crm_analysis
    all_ns = OmnipotentNotificationStatus.where(product_key: @product_key)

    @total_records     = all_ns.count
    @status_breakdown  = all_ns.group(:status).count
    @channel_breakdown = all_ns.where.not(channel: [nil, ""]).group(:channel).count
    @result_breakdown  = all_ns.where.not(result:  [nil, ""]).group(:result).count

    contacted    = all_ns.where.not(contacted_at: nil).count
    with_result  = all_ns.where.not(result: [nil, ""]).count
    ordered_count = all_ns.where(result: "已訂購").count
    @contact_success_rate = contacted > 0 ? (with_result.to_f / contacted * 100).round(1) : 0
    @order_rate = contacted > 0 ? (ordered_count.to_f / contacted * 100).round(1) : 0

    @recent_activity = all_ns.where.not(status: "未通知").order(updated_at: :desc).limit(20)

    @monthly_activity = 5.downto(0).map do |i|
      m = Date.today << i; ms = m.beginning_of_month; me = m.end_of_month
      ns = all_ns.where(notified_at: ms..me)
      { label: m.strftime("%m月"), total: ns.count,
        replied: ns.where(status: "已回覆").count,
        ordered: ns.where(result: "已訂購").count }
    end
  end

  def broadcast_performance
    events = OmnipotentAnalysisController::OMNI_EVENTS.select { |e| e[:date] <= Date.today }

    all_event_emails = []
    events.each do |ev|
      win_start = ev[:date]; win_end = ev[:date] + 3
      emails = ShoplineOrder.where(@product[:sql])
        .where("order_date::date BETWEEN ? AND ?", win_start, win_end)
        .where.not(email: [nil, ""]).distinct.pluck(:email)
      all_event_emails.concat(emails)
    end
    all_event_emails.uniq!

    all_later_orders = Hash.new { |h, k| h[k] = [] }
    if all_event_emails.any?
      ShoplineOrder.where(@product[:sql]).where(email: all_event_emails)
        .order(:email, :order_date)
        .pluck(:email, :order_date, :order_number)
        .each { |em, od, on_| all_later_orders[em] << { date: od.to_date, order_number: on_ } }
    end

    @event_stats = events.map do |ev|
      win_start = ev[:date]; win_end = ev[:date] + 3
      event_orders = ShoplineOrder.where(@product[:sql])
        .where("order_date::date BETWEEN ? AND ?", win_start, win_end)
        .where.not(email: [nil, ""])
      buyer_emails = event_orders.distinct.pluck(:email)
      next if buyer_emails.empty?

      order_nums = event_orders.distinct.pluck(:order_number).compact
      event_revenue = 0
      if order_nums.any?
        event_revenue = ShoplineOrder.where(order_number: order_nums)
          .group(:order_number)
          .pluck(Arel.sql("COALESCE(MAX(NULLIF(total_amount,0)), SUM(COALESCE(checkout_amount,0)))"))
          .sum(&:to_f).round
      end

      repurchased_emails = buyer_emails.select { |em| all_later_orders[em].any? { |o| o[:date] > win_end } }

      { label: "#{ev[:year]}/#{ev[:label]}", date: ev[:date], note: ev[:note],
        buyers: buyer_emails.size, revenue: event_revenue,
        avg_value: buyer_emails.size > 0 ? (event_revenue.to_f / buyer_emails.size).round : 0,
        repurchased: repurchased_emails.size,
        repurchase_rate: buyer_emails.size > 0 ? (repurchased_emails.size.to_f / buyer_emails.size * 100).round(1) : 0 }
    end.compact.sort_by { |e| -e[:date].to_time.to_i }
  end

  # ── Exports ────────────────────────────────────────────────────────

  def export
    send_data "\xEF\xBB\xBF" + restock_csv(@today),
              filename: "#{@product[:label]}_維護名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_at_risk
    send_data "\xEF\xBB\xBF" + restock_csv(@at_risk),
              filename: "#{@product[:label]}_流失喚醒名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_loyal
    send_data "\xEF\xBB\xBF" + loyal_csv,
              filename: "#{@product[:label]}_常購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def update_status
    ns = OmnipotentNotificationStatus.find_or_initialize_by(
      email:          params[:email],
      reference_date: params[:reference_date],
      product_key:    params[:product_key].presence || "omnipotent"
    )
    ns.status      = params[:status]      if params[:status].present?
    ns.notified_at = Time.current         if params[:status] == "已通知" && ns.notified_at.nil?
    ns.channel     = params[:channel]     if params[:channel].present?
    ns.result      = params[:result]      if params[:result].present?
    if params[:contacted_at].present?
      ns.contacted_at = Date.parse(params[:contacted_at])
    elsif ns.contacted_at.nil? && params[:status].present? && params[:status] != "未通知"
      ns.contacted_at = Date.today
    end
    ns.save!
    render json: { success: true, status: ns.status, channel: ns.channel,
                   result: ns.result, contacted_at: ns.contacted_at&.strftime("%m/%d") }
  rescue => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def build_restock_data
    today      = Date.today
    since_date = today - 365
    sql        = @product[:sql]

    orders_raw = ShoplineOrder
      .where(sql).where("order_date >= ?", since_date.beginning_of_day)
      .where.not(email: [nil, ""])
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date.to_date }
    end

    return (@restock_list = @remind_now = @overdue = @at_risk = @not_urgent = []) if last_order_by_email.empty?

    all_emails = last_order_by_email.keys

    omni_counts = ShoplineOrder.where(sql).where(email: all_emails).group(:email).count

    bottle_totals = Hash.new(0)
    ShoplineOrder.where(sql).where(email: all_emails).pluck(:email, :product_name).each do |email, pn|
      bottle_totals[email] += extract_bottles(pn)
    end

    notif_map = {}
    OmnipotentNotificationStatus.where(email: all_emails, product_key: @product_key).each do |n|
      notif_map[[n.email, n.reference_date]] = n
    end

    customers = ShoplineCustomer
      .where(email: all_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @restock_list = customers.map do |c|
      order   = last_order_by_email[c.email]
      bought  = order[:order_date]
      bottles = extract_bottles(order[:product_name])

      estimated_finish_date   = bought + bottles * 30
      expected_return_date    = bought + expected_days(bottles)
      suggested_reminder_date = expected_return_date - REMINDER_BUFFER_DAYS
      days_left               = (expected_return_date   - today).to_i
      days_until_reminder     = (suggested_reminder_date - today).to_i
      count                   = omni_counts[c.email]   || 0
      total_bottles           = bottle_totals[c.email] || 0

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
    @today      = (@remind_now + @overdue).sort_by { |r| -r[:crm_score] }
    @high_value_count = @today.count { |r| [:vip, :big].include?(r[:customer_type][:key]) }
  end

  def build_loyal_buyers
    sql   = @product[:sql]
    order_counts = ShoplineOrder.where(sql).where.not(email: [nil, ""]).group(:email).count
    loyal_emails = order_counts.select { |_, n| n >= LOYAL_THRESHOLD }.keys
    return (@loyal_buyers = []) if loyal_emails.empty?

    bottle_totals = Hash.new(0)
    ShoplineOrder.where(sql).where(email: loyal_emails).pluck(:email, :product_name).each do |email, pn|
      bottle_totals[email] += extract_bottles(pn)
    end

    last_dates = {}
    ShoplineOrder.where(sql).where(email: loyal_emails)
      .order(:email, order_date: :desc).pluck(:email, :order_date)
      .each { |email, date| last_dates[email] ||= date&.to_date }

    amounts = Hash.new(0.0)
    ShoplineOrder.where(sql).where(email: loyal_emails)
      .group(:email, :order_number)
      .pluck(:email,
             Arel.sql("MAX(NULLIF(total_amount, 0))"),
             Arel.sql("SUM(COALESCE(checkout_amount, 0))"))
      .each { |email, max_total, sum_checkout| amounts[email] += (max_total || sum_checkout).to_f }

    customers = ShoplineCustomer
      .where(email: loyal_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)

    @loyal_buyers = customers.map do |c|
      count         = order_counts[c.email]  || 0
      total_bottles = bottle_totals[c.email] || 0
      { customer: c, order_count: count, total_spend: amounts[c.email] || 0,
        last_date: last_dates[c.email], total_bottles: total_bottles,
        customer_type: resolve_customer_type(count, total_bottles) }
    end.sort_by { |r| [-r[:customer_type][:rank], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:order_count], -r[:total_spend]] }
  end

  # ── Helpers ────────────────────────────────────────────────────────

  def calc_crm_score(row)
    score  = CRM_SCORE[:type][row[:customer_type][:key]] || 0
    score += CRM_SCORE[:from_broadcast] if row[:source_event] != "一般購買"
    score += CRM_SCORE[:repeat_buyer]   if row[:omni_count] > 1
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
    return "一般購買" unless bought_date
    event = OmnipotentAnalysisController::OMNI_EVENTS.find do |e|
      (e[:date]..(e[:date] + 3)).cover?(bought_date)
    end
    event ? "#{event[:year]}/#{event[:label]}" : "一般購買"
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m    = product_name.match(@product[:regex])
    base = if m
      m[1].to_i
    elsif (m2 = product_name.match(/[（(](\d+)[瓶盒]/))
      m2[1].to_i
    else
      1
    end
    base + (product_name.match(/送(\d+)/)&.[](1).to_i || 0)
  end

  def expected_days(bottles)
    medians = @product[:medians]
    return medians[bottles] if medians.key?(bottles)
    keys = medians.keys.sort
    lo = keys.select { |k| k < bottles }.last
    hi = keys.select { |k| k > bottles }.first
    return medians[lo || hi] unless lo && hi
    lo_v = medians[lo]; hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end

  def restock_csv(rows)
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["狀態", "客戶類型", "姓名", "卡別", "IG", "來源場次",
              "上次購買", "瓶數", "累計瓶數", "累計次數",
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
      csv << ["客戶類型", "姓名", "卡別", "IG", "購買次數", "累計瓶數", "累計消費(NT$)", "上次購買"]
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
