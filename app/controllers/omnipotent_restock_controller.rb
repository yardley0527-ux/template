class OmnipotentRestockController < ApplicationController
  include JourneyProducts
  include MembershipLevels

  REMINDER_BUFFER_DAYS = 7

  CUSTOMER_TYPES = [
    { key: :vip,    label: "VIP常購客", emoji: "🔵", color: "#1d4ed8", rank: 4, desc: "連續兩波進貨都有回購，且累計 6 瓶以上" },
    { key: :big,    label: "大套組客",  emoji: "🟠", color: "#ea580c", rank: 3, desc: "累計 6 瓶以上" },
    { key: :small,  label: "小套組客",  emoji: "🟡", color: "#ca8a04", rank: 2, desc: "累計 3–5 瓶" },
    { key: :single, label: "單瓶客",    emoji: "🟢", color: "#6b7280", rank: 1, desc: "累計 1–2 瓶" }
  ].freeze

  ATTRIBUTION_WINDOW = 45

  before_action :set_product

  # ── Main actions ──────────────────────────────────────────────────

  def customer_journey
    @customer    = ShoplineCustomer.find(params[:id])
    @omni_orders = ShoplineOrder.where(@product[:sql]).where(email: @customer.email)
      .order(order_date: :desc)
      .pluck(:product_name, :order_date, :order_number)
      .map { |pn, od, on_| { product_name: pn, order_date: od&.to_date, order_number: on_,
                              bottles: extract_bottles(pn, @product), source_event: source_event_label(od&.to_date) } }
    @contact_history = OmnipotentNotificationStatus
      .where(email: @customer.email, product_key: @product_key).order(reference_date: :desc)
    if @omni_orders.any?
      latest = @omni_orders.first
      b = latest[:bottles]; bought = latest[:order_date]; exp = expected_days(b, @product)
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
      cross_wave_repeat   = WaveRepeatCalculator.call(@product[:sql]).fetch(@customer.email, false)
      @customer_type      = resolve_customer_type(cross_wave_repeat, tb)
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
      bottles   = extract_bottles(pn, @product)
      predicted = ref_date + expected_days(bottles, @product)
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

  # ── Exports ────────────────────────────────────────────────────────

  private

  # 沒帶 ?product= 時：合併所有 in_stock: true 產品的「今日應聯絡」名單。
  #
  # 篩選/名單產生仍以 JourneyProducts.in_stock（手動維護旗標）為準——
  # crm_products.availability_status 這 13 個產品目前全部是 unknown（Gate 3
  # 2026-07-21 查證），尚未有任何一個經人工確認，若這時把「是否要不要產生名單」
  # 這種判斷切到 crm_products，等於用一個全新表全部都是「未確認」的訊號去關掉
  # 現在正常運作的名單產生（等同一次靜默 regression）。crm_availability_status
  # 只做「附加顯示」用──在名單上多秀一個徽章，讓使用者知道 CRM 庫存表對這個

  # ── Helpers ────────────────────────────────────────────────────────

  def resolve_customer_type(cross_wave_repeat, total_bottles)
    if cross_wave_repeat && total_bottles >= 6
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

  def extract_bottles(product_name, product)
    return 1 if product_name.nil?
    m    = product_name.match(product[:regex])
    base = if m
      m[1].to_i
    elsif (m2 = product_name.match(/[（(](\d+)[瓶盒]/))
      m2[1].to_i
    else
      1
    end
    base + (product_name.match(/送(\d+)/)&.[](1).to_i || 0)
  end

  def expected_days(bottles, product)
    medians = product[:medians]
    return medians[bottles] if medians.key?(bottles)
    keys = medians.keys.sort
    lo = keys.select { |k| k < bottles }.last
    hi = keys.select { |k| k > bottles }.first
    return medians[lo || hi] unless lo && hi
    lo_v = medians[lo]; hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end

end
