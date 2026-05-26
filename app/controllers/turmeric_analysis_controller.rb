# frozen_string_literal: true

class TurmericAnalysisController < ApplicationController
  TURMERIC = "product_name LIKE '%薑黃%'"
  TURMERIC_BOTTLES_REGEX = /薑黃(\d+)/
  DAYS_PER_BOTTLE = 30

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡].freeze

  def index
    jan9  = Date.new(2026, 1, 8).beginning_of_day..Date.new(2026, 1, 12).end_of_day
    feb25 = Date.new(2026, 2, 24).beginning_of_day..Date.new(2026, 2, 28).end_of_day
    apr10 = Date.new(2026, 4, 9).beginning_of_day..Date.new(2026, 4, 13).end_of_day

    @jan9_emails  = turmeric_emails(jan9)
    @feb25_emails = turmeric_emails(feb25)
    @apr10_emails = turmeric_emails(apr10)

    @jan9_to_feb25_count  = (@jan9_emails & @feb25_emails).size
    @feb25_to_apr10_count = (@feb25_emails & @apr10_emails).size
    @all_prev_emails      = (@jan9_emails | @feb25_emails).uniq
    @prev_to_apr10_count  = (@all_prev_emails & @apr10_emails).size

    @jan9_return_rate  = pct(@jan9_to_feb25_count, @jan9_emails.size)
    @feb25_return_rate = pct(@feb25_to_apr10_count, @feb25_emails.size)
    @prev_return_rate  = pct(@prev_to_apr10_count, @all_prev_emails.size)

    black_emails = ShoplineCustomer.where(membership_level: "黑卡").where.not(email: [nil, ""]).pluck(:email)
    gold_emails  = ShoplineCustomer.where(membership_level: "金卡").where.not(email: [nil, ""]).pluck(:email)

    @black_card_total = ShoplineCustomer.where(membership_level: "黑卡").where.not(shopline_id: nil).count
    @gold_card_total  = ShoplineCustomer.where(membership_level: "金卡").where.not(shopline_id: nil).count

    @black_jan9  = (black_emails & @jan9_emails).size
    @black_feb25 = (black_emails & @feb25_emails).size
    @black_apr10 = (black_emails & @apr10_emails).size

    @gold_jan9   = (gold_emails & @jan9_emails).size
    @gold_feb25  = (gold_emails & @feb25_emails).size
    @gold_apr10  = (gold_emails & @apr10_emails).size

    @black_jan9_rate  = pct(@black_jan9,  @black_card_total)
    @black_feb25_rate = pct(@black_feb25, @black_card_total)
    @black_apr10_rate = pct(@black_apr10, @black_card_total)
    @gold_jan9_rate   = pct(@gold_jan9,   @gold_card_total)
    @gold_feb25_rate  = pct(@gold_feb25,  @gold_card_total)
    @gold_apr10_rate  = pct(@gold_apr10,  @gold_card_total)

    missing_emails = @all_prev_emails - @apr10_emails

    last_orders_raw = ShoplineOrder
      .where(TURMERIC)
      .where(email: missing_emails)
      .where(order_date: jan9.first..feb25.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    last_orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts = ShoplineOrder.where(TURMERIC).where(email: missing_emails).group(:email).count
    history_amounts = ShoplineOrder.where(TURMERIC).where(email: missing_emails).group(:email).sum(:total_amount)

    customers = ShoplineCustomer
      .where(membership_level: TARGET_MEMBERSHIPS)
      .where(email: missing_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    today = Date.today

    @missing_customers = customers.map do |c|
      last = last_order_by_email[c.email]
      bottles = extract_bottles(last&.dig(:product_name))
      last_date = last&.dig(:order_date)&.to_date
      expected_days = bottles * DAYS_PER_BOTTLE
      overdue_days = last_date ? (today - last_date).to_i - expected_days : nil

      history_count  = history_counts[c.email] || 0
      history_amount = history_amounts[c.email] || 0
      membership_rank = MEMBERSHIP_RANK[c.membership_level] || 0

      overdue_score  = overdue_days ? [overdue_days, 0].max / 10.0 : 0
      priority_score = (membership_rank * 3) + overdue_score + (history_count * 0.5)

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

    loyal_3_emails = @jan9_emails & @feb25_emails & @apr10_emails
    loyal_2_emails = (
      (@jan9_emails & @feb25_emails) |
      (@feb25_emails & @apr10_emails) |
      (@jan9_emails & @apr10_emails)
    ).uniq - loyal_3_emails

    build_loyal = lambda do |emails|
      return [] if emails.empty?

      apr10_orders = ShoplineOrder
        .where(TURMERIC).where(email: emails).where(order_date: apr10)
        .order(:email, order_date: :desc)
        .pluck(:email, :product_name, :order_date)

      apr10_by_email = {}
      apr10_orders.each { |email, product_name, order_date| apr10_by_email[email] ||= { product_name: product_name, order_date: order_date } }

      prev_orders = ShoplineOrder
        .where(TURMERIC).where(email: emails).where(order_date: jan9.first..feb25.last)
        .order(:email, order_date: :desc).pluck(:email, :order_date)

      prev_date_by_email = {}
      prev_orders.each { |email, order_date| prev_date_by_email[email] ||= order_date }

      h_counts  = ShoplineOrder.where(TURMERIC).where(email: emails).group(:email).count
      h_amounts = ShoplineOrder.where(TURMERIC).where(email: emails).group(:email).sum(:total_amount)

      ShoplineCustomer
        .where(email: emails).where(membership_level: TARGET_MEMBERSHIPS)
        .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
        .map do |c|
          apr10_order = apr10_by_email[c.email]
          bottles = extract_bottles(apr10_order&.dig(:product_name))
          {
            customer:       c,
            last_product:   apr10_order&.dig(:product_name),
            last_date:      prev_date_by_email[c.email]&.to_date,
            bottles:        bottles,
            history_count:  h_counts[c.email] || 0,
            history_amount: h_amounts[c.email] || 0
          }
        end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:bottles], -r[:history_amount].to_f] }
    end

    @loyal_3_customers = build_loyal.call(loyal_3_emails)
    @loyal_2_customers = build_loyal.call(loyal_2_emails)

    @insights = []

    if @black_jan9_rate > @gold_jan9_rate
      @insights << { type: :info, text: "黑卡客人對薑黃直播的黏著度（#{@black_jan9_rate}%）高於金卡（#{@gold_jan9_rate}%），維護黑卡關係是提升業績的關鍵。" }
    end
    if @feb25_emails.size < @jan9_emails.size * 0.7
      @insights << { type: :warning, text: "2/25 薑黃購買人數（#{@feb25_emails.size} 人）較 1/9（#{@jan9_emails.size} 人）明顯下滑，需確認是否因多產品場次分散了薑黃買氣。" }
    end
    if @apr10_emails.size >= @jan9_emails.size * 0.8
      @insights << { type: :success, text: "4/10 薑黃品牌之夜出席人數（#{@apr10_emails.size} 人）接近 1/9 水準，純薑黃主題直播吸引力較強。" }
    end
    if @prev_return_rate < 20
      @insights << { type: :warning, text: "曾買過薑黃的客人整體回流率為 #{@prev_return_rate}%，低於 20%，建議加強直播前主動提醒機制。" }
    else
      @insights << { type: :success, text: "曾買過薑黃的客人整體回流率為 #{@prev_return_rate}%，表現良好。" }
    end
    overdue_count = @missing_customers.count { |r| r[:overdue_days] && r[:overdue_days] > 14 }
    if overdue_count > 0
      @insights << { type: :danger, text: "有 #{overdue_count} 位金卡以上客人逾期超過 14 天未回購，建議立即聯繫，優先從黑卡開始。" }
    end
    black_missing = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
    if black_missing > 0
      @insights << { type: :danger, text: "#{black_missing} 位黑卡客人在 1/9 或 2/25 有買薑黃，但 4/10 未出現，流失風險最高，需優先追蹤。" }
    end
    @insights << { type: :success, text: "#{@loyal_3_customers.size} 位客人三場都有購買薑黃，是最核心的忠實客，適合邀請成為品牌大使或提供 VIP 優惠。" } if @loyal_3_customers.size > 0
    @insights << { type: :info,    text: "#{@loyal_2_customers.size} 位客人任意兩場有購買，具穩定回購習慣，下次直播前 3 天建議主動提醒。" } if @loyal_2_customers.size > 0
    if @black_apr10_rate < 20 && @black_jan9_rate < 20
      @insights << { type: :warning, text: "黑卡客人連續兩場出席率均低於 20%，建議檢視通知方式或提供黑卡專屬誘因。" }
    end

    jan9_revenue  = turmeric_revenue(jan9)
    feb25_revenue = turmeric_revenue(feb25)
    apr10_revenue = turmeric_revenue(apr10)

    @cross_event_stats = [
      { label: "2026/1/9~1/12",   note: "代謝+膠原、薑黃",   buyers: @jan9_emails.size,  revenue: jan9_revenue,  aov: turmeric_aov(jan9),  return_rate: nil,              return_count: nil },
      { label: "2026/2/25~2/28",  note: "薑黃、清纖粉、代謝", buyers: @feb25_emails.size, revenue: feb25_revenue, aov: turmeric_aov(feb25), return_rate: @jan9_return_rate, return_count: @jan9_to_feb25_count },
      { label: "2026/4/10~4/13",  note: "薑黃",              buyers: @apr10_emails.size, revenue: apr10_revenue, aov: turmeric_aov(apr10), return_rate: @feb25_return_rate, return_count: @feb25_to_apr10_count },
    ]
    @iron_fans = @loyal_3_customers.map { |r| { customer: r[:customer], attended_count: 3 } }
    @high_risk_lost = @missing_customers.map do |r|
      attended = []
      attended << "2026/1/9"  if @jan9_emails.include?(r[:customer].email)
      attended << "2026/2/25" if @feb25_emails.include?(r[:customer].email)
      { customer: r[:customer], attended_labels: attended }
    end

    all_buyers = (@jan9_emails | @feb25_emails | @apr10_emails).uniq
    turmeric_last_raw = ShoplineOrder
      .where(TURMERIC).where(email: all_buyers)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    turmeric_last_by_email = {}
    turmeric_last_raw.each { |e, p, d| turmeric_last_by_email[e] ||= { product_name: p, order_date: d } }

    @expiring_soon = ShoplineCustomer
      .where(email: all_buyers)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .filter_map do |c|
        last = turmeric_last_by_email[c.email]
        next unless last
        bottles   = extract_bottles(last[:product_name])
        last_date = last[:order_date].to_date
        days_left = (bottles * DAYS_PER_BOTTLE) - (today - last_date).to_i
        next unless days_left >= -7 && days_left <= 21
        { customer: c, days_left: days_left, last_product: last[:product_name], last_date: last_date }
      end
      .sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }
  end

  private

  def turmeric_emails(range)
    ShoplineOrder.where(TURMERIC).where(order_date: range).where.not(email: [nil, ""]).distinct.pluck(:email)
  end

  def turmeric_revenue(range)
    ShoplineOrder.where(TURMERIC).where(order_date: range).where.not(total_amount: nil).sum(:total_amount).to_i
  end

  def turmeric_aov(range)
    orders = ShoplineOrder.where(TURMERIC).where(order_date: range).where.not(total_amount: nil)
    return 0 if orders.empty?
    uniq = orders.select(:order_number).distinct.count
    uniq.zero? ? 0 : (orders.sum(:total_amount) / uniq).round(0).to_i
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(TURMERIC_BOTTLES_REGEX)
    m ? m[1].to_i : 1
  end

  def pct(num, den)
    return 0.0 if den.zero?
    (num.to_f / den * 100).round(1)
  end
end
