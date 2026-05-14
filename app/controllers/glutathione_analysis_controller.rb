class GlutathioneAnalysisController < ApplicationController
  GLUTATHIONE = "product_name LIKE '%穀胱甘肽%'"
  GLUTATHIONE_BOTTLES_REGEX = /穀胱甘肽(\d+)/
  DAYS_PER_BOTTLE = 30

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡].freeze

  EVENT_RANGE = Date.new(2026, 1, 22).beginning_of_day..Date.new(2026, 1, 24).end_of_day

  def index
    @jan23_emails = glutathione_emails(EVENT_RANGE)

    all_prev_emails = ShoplineOrder
      .where(GLUTATHIONE)
      .where("order_date < ?", EVENT_RANGE.first)
      .where.not(email: [nil, ""])
      .distinct
      .pluck(:email)

    @prev_count          = all_prev_emails.size
    @prev_returned_count = (all_prev_emails & @jan23_emails).size
    @prev_return_rate    = pct(@prev_returned_count, @prev_count)

    black_emails = ShoplineCustomer.where(membership_level: "黑卡").where.not(email: [nil, ""]).pluck(:email)
    gold_emails  = ShoplineCustomer.where(membership_level: "金卡").where.not(email: [nil, ""]).pluck(:email)

    @black_card_total = ShoplineCustomer.where(membership_level: "黑卡").where.not(shopline_id: nil).count
    @gold_card_total  = ShoplineCustomer.where(membership_level: "金卡").where.not(shopline_id: nil).count

    @black_jan23      = (black_emails & @jan23_emails).size
    @gold_jan23       = (gold_emails  & @jan23_emails).size
    @black_jan23_rate = pct(@black_jan23, @black_card_total)
    @gold_jan23_rate  = pct(@gold_jan23,  @gold_card_total)

    # ── 曾買、1/23 未出現（黑卡/金卡）─────────────────────────────────────────
    missing_emails = all_prev_emails - @jan23_emails
    today = Date.today

    last_orders_raw = ShoplineOrder
      .where(GLUTATHIONE)
      .where(email: missing_emails)
      .where("order_date < ?", EVENT_RANGE.first)
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

    # ── 1/23 購買的黑卡/金卡客人 ──────────────────────────────────────────────
    jan23_orders_raw = ShoplineOrder
      .where(GLUTATHIONE)
      .where(email: @jan23_emails)
      .where(order_date: EVENT_RANGE)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    jan23_by_email = {}
    jan23_orders_raw.each do |email, product_name, order_date|
      jan23_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    h_counts  = ShoplineOrder.where(GLUTATHIONE).where(email: @jan23_emails).group(:email).count
    h_amounts = ShoplineOrder.where(GLUTATHIONE).where(email: @jan23_emails).group(:email).sum(:total_amount)

    @jan23_customers = ShoplineCustomer
      .where(email: @jan23_emails)
      .where(membership_level: TARGET_MEMBERSHIPS)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .map do |c|
        order = jan23_by_email[c.email]
        {
          customer:       c,
          last_product:   order&.dig(:product_name),
          last_date:      order&.dig(:order_date)&.to_date,
          bottles:        extract_bottles(order&.dig(:product_name)),
          history_count:  h_counts[c.email]  || 0,
          history_amount: h_amounts[c.email] || 0
        }
      end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_amount].to_f] }

    # ── Insights ──────────────────────────────────────────────────────────────
    @insights = []

    if @black_jan23_rate > @gold_jan23_rate
      @insights << { type: :info, text: "黑卡客人對穀胱甘肽直播的參與率（#{@black_jan23_rate}%）高於金卡（#{@gold_jan23_rate}%），黑卡是核心推廣對象。" }
    elsif @gold_jan23_rate > @black_jan23_rate
      @insights << { type: :info, text: "金卡客人參與率（#{@gold_jan23_rate}%）高於黑卡（#{@black_jan23_rate}%），可針對黑卡加強個人化邀請。" }
    end

    if @prev_count > 0
      if @prev_return_rate >= 30
        @insights << { type: :success, text: "曾購買過穀胱甘肽的客人，有 #{@prev_return_rate}%（#{@prev_returned_count}/#{@prev_count} 人）在 1/23 再次購買，回流率良好。" }
      else
        @insights << { type: :warning, text: "曾購買過穀胱甘肽的客人回流率為 #{@prev_return_rate}%（#{@prev_returned_count}/#{@prev_count} 人），建議下次直播前主動提醒。" }
      end
    end

    overdue_count = @missing_customers.count { |r| r[:overdue_days] && r[:overdue_days] > 14 }
    @insights << { type: :danger, text: "有 #{overdue_count} 位金卡以上客人逾期超過 14 天未回購，建議立即聯繫。" } if overdue_count > 0

    black_missing = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
    @insights << { type: :danger, text: "#{black_missing} 位黑卡客人曾購買穀胱甘肽但 1/23 未出現，流失風險最高，請優先追蹤。" } if black_missing > 0

    @insights << { type: :success, text: "#{@jan23_customers.size} 位黑卡/金卡客人在 1/23 購買穀胱甘肽，是本場核心客群。" } if @jan23_customers.any?
    @insights << { type: :info,    text: "本場穀胱甘肽直播共吸引 #{@jan23_emails.size} 位不重複買家。" }
  end

  private

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
