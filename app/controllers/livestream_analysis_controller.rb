class LivestreamAnalysisController < ApplicationController
  TURMERIC = "product_name LIKE '%薑黃%'"
  TURMERIC_BOTTLES_REGEX = /薑黃(\d+)/
  DAYS_PER_BOTTLE = 30

  MEMBERSHIP_RANK = {
    "黑卡"   => 5,
    "金卡"   => 4,
    "銀卡"   => 3,
    "白卡"   => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡].freeze

def index
  jan9  = Date.new(2026, 1, 8).beginning_of_day..Date.new(2026, 1, 10).end_of_day
  feb25 = Date.new(2026, 2, 24).beginning_of_day..Date.new(2026, 2, 26).end_of_day
  apr10 = Date.new(2026, 4, 9).beginning_of_day..Date.new(2026, 4, 11).end_of_day

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

  # 黑卡金卡有 email 的名單（不限 shopline_id）
  black_emails = ShoplineCustomer.where(membership_level: "黑卡").where.not(email: [nil, ""]).pluck(:email)
  gold_emails  = ShoplineCustomer.where(membership_level: "金卡").where.not(email: [nil, ""]).pluck(:email)

  # 總人數維持用 shopline_id 的 83/240
  @black_card_total = ShoplineCustomer.where(membership_level: "黑卡").where.not(shopline_id: nil).count
  @gold_card_total  = ShoplineCustomer.where(membership_level: "金卡").where.not(shopline_id: nil).count

  # 各場出席人數
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

  history_counts = ShoplineOrder
    .where(TURMERIC)
    .where(email: missing_emails)
    .group(:email)
    .count

  history_amounts = ShoplineOrder
    .where(TURMERIC)
    .where(email: missing_emails)
    .group(:email)
    .sum(:total_amount)

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

    history_count = history_counts[c.email] || 0
    history_amount = history_amounts[c.email] || 0
    membership_rank = MEMBERSHIP_RANK[c.membership_level] || 0

    overdue_score = overdue_days ? [overdue_days, 0].max / 10.0 : 0
    priority_score = (membership_rank * 3) + overdue_score + (history_count * 0.5)

    {
      customer: c,
      last_product: last&.dig(:product_name),
      last_date: last_date,
      bottles: bottles,
      expected_days: expected_days,
      overdue_days: overdue_days,
      history_count: history_count,
      history_amount: history_amount,
      priority_score: priority_score.round(1)
    }
  end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:priority_score], -r[:history_amount].to_f] }
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
      .where(TURMERIC)
      .where(email: emails)
      .where(order_date: apr10)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    apr10_by_email = {}
    apr10_orders.each do |email, product_name, order_date|
      apr10_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    prev_orders = ShoplineOrder
      .where(TURMERIC)
      .where(email: emails)
      .where(order_date: jan9.first..feb25.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :order_date)

    prev_date_by_email = {}
    prev_orders.each do |email, order_date|
      prev_date_by_email[email] ||= order_date
    end

    h_counts  = ShoplineOrder.where(TURMERIC).where(email: emails).group(:email).count
    h_amounts = ShoplineOrder.where(TURMERIC).where(email: emails).group(:email).sum(:total_amount)

    ShoplineCustomer
      .where(email: emails)
      .where(membership_level: TARGET_MEMBERSHIPS)  # 加這行
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .map do |c|
        apr10_order = apr10_by_email[c.email]
        bottles = extract_bottles(apr10_order&.dig(:product_name))
        {
          customer: c,
          last_product: apr10_order&.dig(:product_name),
          last_date: prev_date_by_email[c.email]&.to_date,
          bottles: bottles,
          history_count: h_counts[c.email] || 0,
          history_amount: h_amounts[c.email] || 0
        }
      end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:bottles], -r[:history_amount].to_f] }
  end

  @loyal_3_customers = build_loyal.call(loyal_3_emails)
  @loyal_2_customers = build_loyal.call(loyal_2_emails)
end

  private

  def turmeric_emails(range)
    ShoplineOrder
      .where(TURMERIC)
      .where(order_date: range)
      .where.not(email: [nil, ""])
      .distinct
      .pluck(:email)
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