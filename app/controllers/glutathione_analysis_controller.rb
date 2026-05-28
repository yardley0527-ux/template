class GlutathioneAnalysisController < ApplicationController
  GLUTATHIONE           = "product_name LIKE '%穀胱甘肽%'"
  GLUTATHIONE_BOTTLES_REGEX = /穀胱甘肽(\d+)/
  DAYS_PER_BOTTLE       = 30

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze

  LEVEL_KEYS = {
    "黑卡"    => "black",
    "金卡"    => "gold",
    "銀卡"    => "silver",
    "白卡"    => "white",
    "一般會員" => "normal"
  }.freeze

  GLUT_EVENTS = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| e[:note]&.include?("穀胱甘肽") }
    .freeze

  before_action :build_analysis_data, only: [:index, :export_missing, :export_event]

  def index
    @all_glut_events = GLUT_EVENTS.select { |e| e[:date] <= Date.today }
    build_comprehensive_data
  end

  def export_missing
    send_data "\xEF\xBB\xBF" + missing_csv,
              filename: "穀胱甘肽_未回購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_event
    send_data "\xEF\xBB\xBF" + event_csv,
              filename: "穀胱甘肽_#{@event_label}購買名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_analysis_data
    past_events    = GLUT_EVENTS.select { |e| e[:date] <= Date.today }
    selected_date  = params[:event].presence && Date.parse(params[:event]) rescue nil
    @current_event = (selected_date && past_events.find { |e| e[:date] == selected_date }) || past_events.last
    return (@event_emails = []) unless @current_event

    @event_label = "#{@current_event[:year]}/#{@current_event[:label]}"
    event_range  = @current_event[:date].beginning_of_day..(@current_event[:date] + 3).end_of_day

    @event_emails = glutathione_emails(event_range)

    all_prev_emails = ShoplineOrder
      .where(GLUTATHIONE)
      .where("order_date < ?", event_range.first)
      .where.not(email: [nil, ""])
      .distinct
      .pluck(:email)

    @prev_count          = all_prev_emails.size
    @prev_returned_count = (all_prev_emails & @event_emails).size
    @prev_return_rate    = pct(@prev_returned_count, @prev_count)

    @level_stats = TARGET_MEMBERSHIPS.filter_map do |level|
      total = ShoplineCustomer.where(membership_level: level).where.not(shopline_id: nil).count
      next if total.zero?
      emails   = ShoplineCustomer.where(membership_level: level).where.not(email: [nil, ""]).pluck(:email)
      attended = (emails & @event_emails).size
      { level: level, total: total, attended: attended, rate: pct(attended, total) }
    end

    black_stat        = @level_stats.find { |s| s[:level] == "黑卡" } || {}
    gold_stat         = @level_stats.find { |s| s[:level] == "金卡" } || {}
    @black_event_rate = black_stat[:rate].to_f
    @gold_event_rate  = gold_stat[:rate].to_f

    missing_emails = all_prev_emails - @event_emails
    today = Date.today

    last_orders_raw = ShoplineOrder
      .where(GLUTATHIONE)
      .where(email: missing_emails)
      .where("order_date < ?", event_range.first)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    last_orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts  = ShoplineOrder.where(GLUTATHIONE).where(email: missing_emails).group(:email).count
    history_amounts = ShoplineOrder.where(GLUTATHIONE).where(email: missing_emails).group(:email).sum(:total_amount)

    customers = ShoplineCustomer
      .where(membership_level: TARGET_MEMBERSHIPS)
      .where(email: missing_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    @missing_customers = customers.map do |c|
      last          = last_order_by_email[c.email]
      bottles       = extract_bottles(last&.dig(:product_name))
      last_date     = last&.dig(:order_date)&.to_date
      expected_days = bottles * DAYS_PER_BOTTLE
      overdue_days  = last_date ? (today - last_date).to_i - expected_days : nil

      history_count   = history_counts[c.email]  || 0
      history_amount  = history_amounts[c.email] || 0
      membership_rank = MEMBERSHIP_RANK[c.membership_level] || 0
      overdue_score   = overdue_days ? [overdue_days, 0].max / 10.0 : 0
      priority_score  = (membership_rank * 3) + overdue_score + (history_count * 0.5)

      {
        customer:       c,
        last_product:   last&.dig(:product_name),
        last_date:      last_date,
        bottles:        bottles,
        expected_days:  expected_days,
        overdue_days:   overdue_days,
        history_count:  history_count,
        history_amount: history_amount,
        priority_score: priority_score.round(1)
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_count], -r[:history_amount].to_f] }
     .reject { |r| r[:overdue_days] && r[:overdue_days] <= 0 }

    event_orders_raw = ShoplineOrder
      .where(GLUTATHIONE)
      .where(email: @event_emails)
      .where(order_date: event_range)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date, :checkout_amount, :total_amount)

    event_by_email = {}
    event_orders_raw.each do |email, product_name, order_date, checkout_amount, total_amount|
      event_by_email[email] ||= {
        product_name: product_name,
        order_date:   order_date,
        order_amount: (checkout_amount || total_amount).to_f
      }
    end

    h_counts = ShoplineOrder.where(GLUTATHIONE).where(email: @event_emails).group(:email).count

    @event_customers = ShoplineCustomer
      .where(email: @event_emails)
      .where(membership_level: TARGET_MEMBERSHIPS)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map do |c|
        order        = event_by_email[c.email]
        bottles      = extract_bottles(order&.dig(:product_name))
        order_amount = order&.dig(:order_amount).to_f
        total_spend  = c.total_amount.to_f

        mem_score      = (MEMBERSHIP_RANK[c.membership_level] || 0) * 2
        spend_score    = total_spend >= 200_000 ? 3 : total_spend >= 100_000 ? 2 : total_spend >= 50_000 ? 1 : 0
        purchase_score = bottles >= 3 ? 2 : bottles >= 2 ? 1 : 0
        value_score    = mem_score + spend_score + purchase_score
        value_tier     = value_score >= 12 ? "重點維護" : value_score >= 7 ? "值得追蹤" : "一般客群"

        {
          customer:     c,
          last_product: order&.dig(:product_name),
          last_date:    order&.dig(:order_date)&.to_date,
          bottles:      bottles,
          order_amount: order_amount,
          total_spend:  total_spend,
          glut_count:   h_counts[c.email] || 0,
          value_score:  value_score,
          value_tier:   value_tier
        }
      end.sort_by { |r| [-r[:value_score], -r[:total_spend]] }

    @insights = []

    if @black_event_rate > @gold_event_rate
      @insights << { type: :info, text: "黑卡客人對穀胱甘肽直播的參與率（#{@black_event_rate}%）高於金卡（#{@gold_event_rate}%），黑卡是核心推廣對象。" }
    elsif @gold_event_rate > @black_event_rate
      @insights << { type: :info, text: "金卡客人參與率（#{@gold_event_rate}%）高於黑卡（#{@black_event_rate}%），可針對黑卡加強個人化邀請。" }
    end

    if @prev_count > 0
      if @prev_return_rate >= 30
        @insights << { type: :success, text: "曾購買過穀胱甘肽的客人，有 #{@prev_return_rate}%（#{@prev_returned_count}/#{@prev_count} 人）在 #{@event_label} 再次購買，回流率良好。" }
      else
        @insights << { type: :warning, text: "曾購買過穀胱甘肽的客人回流率為 #{@prev_return_rate}%（#{@prev_returned_count}/#{@prev_count} 人），建議下次直播前主動提醒。" }
      end
    end

    overdue_count = @missing_customers.count { |r| r[:overdue_days] && r[:overdue_days] > 14 }
    @insights << { type: :danger, text: "有 #{overdue_count} 位客人逾期超過 14 天未回購，建議立即聯繫。" } if overdue_count > 0

    black_missing = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
    @insights << { type: :danger, text: "#{black_missing} 位黑卡客人曾購買穀胱甘肽但 #{@event_label} 未出現，流失風險最高，請優先追蹤。" } if black_missing > 0

    if @event_customers.any?
      black_count = @event_customers.count { |r| r[:customer].membership_level == "黑卡" }
      gold_count  = @event_customers.count { |r| r[:customer].membership_level == "金卡" }
      @insights << { type: :success, text: "#{@event_customers.size} 位會員在 #{@event_label} 購買穀胱甘肽（黑卡 #{black_count} 人、金卡 #{gold_count} 人）。" }
    end

    @insights << { type: :info, text: "本場穀胱甘肽直播共吸引 #{@event_emails.size} 位不重複買家。" }
  end

  def missing_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "上次購買穀胱甘肽", "購買瓶數", "預期回購日", "逾期天數", "歷史次數", "歷史消費(NT$)", "IG"]
      @missing_customers.each do |r|
        c             = r[:customer]
        expected_date = r[:last_date] ? (r[:last_date] + r[:expected_days]).strftime("%Y/%m/%d") : ""
        overdue       = r[:overdue_days] ? (r[:overdue_days] > 0 ? "+#{r[:overdue_days]}天" : "未到期") : ""
        csv << [c.full_name, c.membership_level, c.mobile_phone,
                r[:last_date]&.strftime("%Y/%m/%d"), r[:bottles], expected_date,
                overdue, r[:history_count], r[:history_amount].to_i, c.instagram_account]
      end
    end
  end

  def event_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["客戶價值", "姓名", "卡別", "電話", "購買品項", "本次瓶數", "本次金額(NT$)", "整體消費力(NT$)", "穀胱甘肽歷史次數", "IG"]
      @event_customers.each do |r|
        c = r[:customer]
        csv << [r[:value_tier], c.full_name, c.membership_level, c.mobile_phone,
                r[:last_product], r[:bottles], r[:order_amount].to_i,
                r[:total_spend].to_i, r[:glut_count], c.instagram_account]
      end
    end
  end

  def build_comprehensive_data
    return if @all_glut_events.empty?

    all_event_emails = @all_glut_events.map do |ev|
      glutathione_emails(ev[:date].beginning_of_day..(ev[:date] + 3).end_of_day)
    end

    glut_revenues = @all_glut_events.map do |ev|
      range = ev[:date].beginning_of_day..(ev[:date] + 3).end_of_day
      ShoplineOrder.where(GLUTATHIONE).where(order_date: range)
        .sum("COALESCE(checkout_amount, total_amount)")
    end

    @cross_event_stats = @all_glut_events.each_with_index.map do |ev, i|
      emails   = all_event_emails[i]
      prev     = i > 0 ? all_event_emails[i - 1] : []
      overlap  = (prev & emails).size
      end_date = ev[:date] + 3
      rev      = glut_revenues[i].to_i
      single_product = !ev[:note].include?("、") && !ev[:note].include?("+")
      {
        label:          "#{ev[:year]}/#{ev[:label]}~#{end_date.month}/#{end_date.day}",
        note:           ev[:note],
        buyers:         emails.size,
        revenue:        rev,
        aov:            (emails.size > 0 && rev > 0) ? (rev / emails.size) : 0,
        return_rate:    prev.any? ? pct(overlap, prev.size) : nil,
        return_count:   prev.any? ? overlap : nil,
        single_product: single_product
      }
    end

    all_emails = all_event_emails.flatten.uniq
    today      = Date.today

    last_orders_raw = ShoplineOrder
      .where(GLUTATHIONE).where(email: all_emails)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_by_email = {}
    last_orders_raw.each { |e, p, d| last_by_email[e] ||= { product_name: p, order_date: d } }

    @expiring_soon = ShoplineCustomer
      .where(email: all_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .filter_map do |c|
        last = last_by_email[c.email]
        next unless last
        bottles   = extract_bottles(last[:product_name])
        last_date = last[:order_date].to_date
        days_left = (bottles * DAYS_PER_BOTTLE) - (today - last_date).to_i
        next unless days_left >= -7 && days_left <= 21
        { customer: c, days_left: days_left, last_product: last[:product_name], last_date: last_date }
      end
      .sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }

    iron_emails = all_event_emails.reduce(:&)
    @iron_fans = ShoplineCustomer
      .where(email: iron_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map { |c| { customer: c, attended_count: @all_glut_events.size } }
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }

    latest_emails = all_event_emails.last
    lost_emails   = all_event_emails[0..-2].flatten.uniq - latest_emails
    @high_risk_lost = ShoplineCustomer
      .where(email: lost_emails).where(membership_level: %w[黑卡 金卡])
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map do |c|
        attended = @all_glut_events[0..-2].each_with_index
          .select { |_, i| all_event_emails[i].include?(c.email) }
          .map { |ev, _| "#{ev[:year]}/#{ev[:label]}" }
        { customer: c, attended_labels: attended }
      end
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
  end

  def glutathione_emails(range)
    ShoplineOrder
      .where(GLUTATHIONE)
      .where(order_date: range)
      .where.not(email: [nil, ""])
      .distinct
      .pluck(:email)
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(GLUTATHIONE_BOTTLES_REGEX)
    return m[1].to_i if m
    m = product_name.match(/[（(](\d+)[瓶盒]/)
    return m[1].to_i if m
    return 6 if product_name.include?("家庭號")
    1
  end

  def pct(num, den)
    return 0.0 if den.zero?
    (num.to_f / den * 100).round(1)
  end
end
