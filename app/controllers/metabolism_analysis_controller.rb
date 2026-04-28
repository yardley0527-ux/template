require 'csv'

class MetabolismAnalysisController < ApplicationController
  METABOLISM = "product_name LIKE '%代謝%'"
  DAYS_PER_BOTTLE = 30

  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡].freeze

  EVENT_RANGES = {
    jul4:  Date.new(2025,  7,  3).beginning_of_day..Date.new(2025,  7,  5).end_of_day,
    jul22: Date.new(2025,  7, 21).beginning_of_day..Date.new(2025,  7, 23).end_of_day,
    oct9:  Date.new(2025, 10,  8).beginning_of_day..Date.new(2025, 10, 11).end_of_day,
    feb25: Date.new(2026,  2, 24).beginning_of_day..Date.new(2026,  2, 26).end_of_day,
    apr24: Date.new(2026,  4, 23).beginning_of_day..Date.new(2026,  4, 25).end_of_day,
  }.freeze

  def index
    jul4  = EVENT_RANGES[:jul4]
    jul22 = EVENT_RANGES[:jul22]
    oct9  = EVENT_RANGES[:oct9]
    feb25 = EVENT_RANGES[:feb25]
    apr24 = EVENT_RANGES[:apr24]

    # ── 各場購買人 email ──────────────────────────────────────────────────────
    @jul4_emails  = metabolism_emails(jul4)
    @jul22_emails = metabolism_emails(jul22)
    @oct9_emails  = metabolism_emails(oct9)
    @feb25_emails = metabolism_emails(feb25)
    @apr24_emails = metabolism_emails(apr24)

    # ── 連場回購率 ────────────────────────────────────────────────────────────
    @jul4_to_jul22_count  = (@jul4_emails  & @jul22_emails).size
    @jul22_to_oct9_count  = (@jul22_emails & @oct9_emails).size
    @oct9_to_feb25_count  = (@oct9_emails  & @feb25_emails).size
    @feb25_to_apr24_count = (@feb25_emails & @apr24_emails).size

    @jul4_return_rate  = pct(@jul4_to_jul22_count,  @jul4_emails.size)
    @jul22_return_rate = pct(@jul22_to_oct9_count,  @jul22_emails.size)
    @oct9_return_rate  = pct(@oct9_to_feb25_count,  @oct9_emails.size)
    @feb25_return_rate = pct(@feb25_to_apr24_count, @feb25_emails.size)

    prev_4_emails     = (@jul4_emails | @jul22_emails | @oct9_emails | @feb25_emails).uniq
    @prev_return_rate = pct((prev_4_emails & @apr24_emails).size, prev_4_emails.size)

    @all_prev_emails = (prev_4_emails | @apr24_emails).uniq

    # ── 黑卡 / 金卡 各場滲透率 ────────────────────────────────────────────────
    black_emails = ShoplineCustomer.where(membership_level: "黑卡").where.not(email: [nil, ""]).pluck(:email)
    gold_emails  = ShoplineCustomer.where(membership_level: "金卡").where.not(email: [nil, ""]).pluck(:email)

    @black_card_total = ShoplineCustomer.where(membership_level: "黑卡").where.not(shopline_id: nil).count
    @gold_card_total  = ShoplineCustomer.where(membership_level: "金卡").where.not(shopline_id: nil).count

    @black_jul4  = (black_emails & @jul4_emails).size
    @black_jul22 = (black_emails & @jul22_emails).size
    @black_oct9  = (black_emails & @oct9_emails).size
    @black_feb25 = (black_emails & @feb25_emails).size
    @black_apr24 = (black_emails & @apr24_emails).size

    @gold_jul4   = (gold_emails & @jul4_emails).size
    @gold_jul22  = (gold_emails & @jul22_emails).size
    @gold_oct9   = (gold_emails & @oct9_emails).size
    @gold_feb25  = (gold_emails & @feb25_emails).size
    @gold_apr24  = (gold_emails & @apr24_emails).size

    @black_jul4_rate  = pct(@black_jul4,  @black_card_total)
    @black_jul22_rate = pct(@black_jul22, @black_card_total)
    @black_oct9_rate  = pct(@black_oct9,  @black_card_total)
    @black_feb25_rate = pct(@black_feb25, @black_card_total)
    @black_apr24_rate = pct(@black_apr24, @black_card_total)

    @gold_jul4_rate   = pct(@gold_jul4,   @gold_card_total)
    @gold_jul22_rate  = pct(@gold_jul22,  @gold_card_total)
    @gold_oct9_rate   = pct(@gold_oct9,   @gold_card_total)
    @gold_feb25_rate  = pct(@gold_feb25,  @gold_card_total)
    @gold_apr24_rate  = pct(@gold_apr24,  @gold_card_total)

    # ── 各場 Top 商品 / 營收 / AOV ────────────────────────────────────────────
    @jul4_top_products  = top_products(jul4)
    @jul22_top_products = top_products(jul22)
    @oct9_top_products  = top_products(oct9)
    @feb25_top_products = top_products(feb25)
    @apr24_top_products = top_products(apr24)

    @jul4_revenue  = event_revenue(jul4)
    @jul22_revenue = event_revenue(jul22)
    @oct9_revenue  = event_revenue(oct9)
    @feb25_revenue = event_revenue(feb25)
    @apr24_revenue = event_revenue(apr24)

    @jul4_aov  = event_aov(jul4)
    @jul22_aov = event_aov(jul22)
    @oct9_aov  = event_aov(oct9)
    @feb25_aov = event_aov(feb25)
    @apr24_aov = event_aov(apr24)

    @copurchase_products = copurchase_products

    # ── 共用：一次查完所有訂單與消費紀錄 ─────────────────────────────────────
    today = Date.today

    last_orders_raw = ShoplineOrder
      .where(METABOLISM)
      .where(email: @all_prev_emails)
      .where(order_date: jul4.first..apr24.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    last_orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts  = ShoplineOrder.where(METABOLISM).where(email: @all_prev_emails).group(:email).count
    history_amounts = ShoplineOrder.where(METABOLISM).where(email: @all_prev_emails).group(:email).sum(:total_amount)

    # ── 黑卡/金卡逾期分析 ────────────────────────────────────────────────────
    customers = ShoplineCustomer
      .where(membership_level: TARGET_MEMBERSHIPS)
      .where(email: @all_prev_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    all_customers = customers.map do |c|
      last           = last_order_by_email[c.email]
      bottles        = extract_bottles(last&.dig(:product_name))
      last_date      = last&.dig(:order_date)&.to_date
      expected_days  = bottles * DAYS_PER_BOTTLE
      overdue_days   = last_date ? (today - last_date).to_i - expected_days : nil

      {
        customer:       c,
        last_product:   last&.dig(:product_name),
        last_date:      last_date,
        bottles:        bottles,
        expected_days:  expected_days,
        overdue_days:   overdue_days,
        history_count:  history_counts[c.email]  || 0,
        history_amount: history_amounts[c.email] || 0,
        attended_jul4:  @jul4_emails.include?(c.email),
        attended_jul22: @jul22_emails.include?(c.email),
        attended_oct9:  @oct9_emails.include?(c.email),
        attended_feb25: @feb25_emails.include?(c.email),
        attended_apr24: @apr24_emails.include?(c.email),
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_count], -r[:history_amount].to_f] }

    @overdue_customers = all_customers.select { |r| r[:overdue_days].nil? || r[:overdue_days] > 0 }
    @not_due_customers = all_customers.select { |r| r[:overdue_days] && r[:overdue_days] <= 0 }

    # ── ★ 前四場有買、4/24 沒回來（黑卡/金卡） ───────────────────────────────
    @did_not_return = all_customers
      .select { |r| !r[:attended_apr24] }
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -(r[:overdue_days] || -999)] }

    # ── 14 天內即將吃完（全會員等級，複用同一批查詢結果） ────────────────────
    all_customers_for_alert = ShoplineCustomer
      .where(email: @all_prev_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .map do |c|
        last          = last_order_by_email[c.email]
        bottles       = extract_bottles(last&.dig(:product_name))
        last_date     = last&.dig(:order_date)&.to_date
        expected_days = bottles * DAYS_PER_BOTTLE
        overdue_days  = last_date ? (today - last_date).to_i - expected_days : nil

        {
          customer:       c,
          last_product:   last&.dig(:product_name),
          last_date:      last_date,
          bottles:        bottles,
          expected_days:  expected_days,
          overdue_days:   overdue_days,
          days_remaining: overdue_days ? -overdue_days : nil,
          history_count:  history_counts[c.email]  || 0,
          history_amount: history_amounts[c.email] || 0
        }
      end

    @expiring_soon = all_customers_for_alert
      .select { |r| r[:overdue_days] && r[:overdue_days] >= -14 && r[:overdue_days] <= 0 }
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), r[:overdue_days].to_i] }

    # ── 忠實客（五場版） ──────────────────────────────────────────────────────
    loyal_5_emails = @jul4_emails & @jul22_emails & @oct9_emails & @feb25_emails & @apr24_emails

    loyal_4_emails = [
      @jul4_emails  & @jul22_emails & @oct9_emails  & @feb25_emails,
      @jul4_emails  & @jul22_emails & @oct9_emails  & @apr24_emails,
      @jul4_emails  & @jul22_emails & @feb25_emails & @apr24_emails,
      @jul4_emails  & @oct9_emails  & @feb25_emails & @apr24_emails,
      @jul22_emails & @oct9_emails  & @feb25_emails & @apr24_emails,
    ].reduce(:|).uniq - loyal_5_emails

    loyal_3_emails = [
      @jul4_emails  & @jul22_emails & @oct9_emails,
      @jul4_emails  & @jul22_emails & @feb25_emails,
      @jul4_emails  & @jul22_emails & @apr24_emails,
      @jul4_emails  & @oct9_emails  & @feb25_emails,
      @jul4_emails  & @oct9_emails  & @apr24_emails,
      @jul4_emails  & @feb25_emails & @apr24_emails,
      @jul22_emails & @oct9_emails  & @feb25_emails,
      @jul22_emails & @oct9_emails  & @apr24_emails,
      @jul22_emails & @feb25_emails & @apr24_emails,
      @oct9_emails  & @feb25_emails & @apr24_emails,
    ].reduce(:|).uniq - loyal_5_emails - loyal_4_emails

    loyal_2_emails = [
      @jul4_emails  & @jul22_emails,
      @jul4_emails  & @oct9_emails,
      @jul4_emails  & @feb25_emails,
      @jul4_emails  & @apr24_emails,
      @jul22_emails & @oct9_emails,
      @jul22_emails & @feb25_emails,
      @jul22_emails & @apr24_emails,
      @oct9_emails  & @feb25_emails,
      @oct9_emails  & @apr24_emails,
      @feb25_emails & @apr24_emails,
    ].reduce(:|).uniq - loyal_5_emails - loyal_4_emails - loyal_3_emails

    build_loyal = lambda do |emails|
      return [] if emails.empty?

      latest_orders = ShoplineOrder
        .where(METABOLISM)
        .where(email: emails)
        .order(:email, order_date: :desc)
        .pluck(:email, :product_name, :order_date)

      latest_by_email = {}
      latest_orders.each do |email, product_name, order_date|
        latest_by_email[email] ||= { product_name: product_name, order_date: order_date }
      end

      h_counts  = ShoplineOrder.where(METABOLISM).where(email: emails).group(:email).count
      h_amounts = ShoplineOrder.where(METABOLISM).where(email: emails).group(:email).sum(:total_amount)

      ShoplineCustomer
        .where(email: emails)
        .where(membership_level: TARGET_MEMBERSHIPS)
        .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
        .map do |c|
          last_order = latest_by_email[c.email]
          {
            customer:       c,
            last_product:   last_order&.dig(:product_name),
            last_date:      last_order&.dig(:order_date)&.to_date,
            bottles:        extract_bottles(last_order&.dig(:product_name)),
            history_count:  h_counts[c.email]  || 0,
            history_amount: h_amounts[c.email] || 0
          }
        end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_amount].to_f] }
    end

    @loyal_5_customers = build_loyal.call(loyal_5_emails)
    @loyal_4_customers = build_loyal.call(loyal_4_emails)
    @loyal_3_customers = build_loyal.call(loyal_3_emails)
    @loyal_2_customers = build_loyal.call(loyal_2_emails)

    # ── Insights ──────────────────────────────────────────────────────────────
    @insights = []

    did_not_return_count = @did_not_return.size
    @insights << { type: :danger, text: "前四場有購買代謝錠、但 4/24 未回購的黑卡/金卡共 #{did_not_return_count} 人，建議本週內主動追蹤。" } if did_not_return_count > 0

    overdue_count = @did_not_return.count { |r| r[:overdue_days] && r[:overdue_days] > 14 }
    @insights << { type: :danger, text: "其中 #{overdue_count} 位已逾期超過 14 天，代謝錠可能已耗盡，補貨意願最高，優先聯繫。" } if overdue_count > 0

    rates = [@jul4_return_rate, @jul22_return_rate, @oct9_return_rate, @feb25_return_rate]
    if rates.each_cons(2).all? { |a, b| b >= a }
      @insights << { type: :success, text: "連場回購率持續上升（#{@jul4_return_rate}% → #{@jul22_return_rate}% → #{@oct9_return_rate}% → #{@feb25_return_rate}%），品牌忠誠度健康。" }
    else
      @insights << { type: :warning, text: "連場回購率：#{@jul4_return_rate}% → #{@jul22_return_rate}% → #{@oct9_return_rate}% → #{@feb25_return_rate}%，請留意趨勢變化。" }
    end

    @insights << { type: :info,    text: "前四場客人整體回流至 4/24 的比率為 #{@prev_return_rate}%。" }
    @insights << { type: :success, text: "#{@loyal_5_customers.size} 位客人五場全勤購買代謝錠，是最核心忠實客，建議邀請成為品牌大使。" } if @loyal_5_customers.size > 0
    @insights << { type: :success, text: "#{@loyal_4_customers.size} 位客人任四場有購買，高忠誠度客群。" }                                   if @loyal_4_customers.size > 0
    @insights << { type: :info,    text: "#{@loyal_3_customers.size} 位客人任三場有購買。" }                                                  if @loyal_3_customers.size > 0
    @insights << { type: :info,    text: "累計 #{@all_prev_emails.size} 位不重複客人曾在五場中購買代謝錠。" }
  end

  def export
    jul4  = EVENT_RANGES[:jul4]
    jul22 = EVENT_RANGES[:jul22]
    oct9  = EVENT_RANGES[:oct9]
    feb25 = EVENT_RANGES[:feb25]
    apr24 = EVENT_RANGES[:apr24]

    all_prev_emails = (
      metabolism_emails(jul4) |
      metabolism_emails(jul22) |
      metabolism_emails(oct9) |
      metabolism_emails(feb25) |
      metabolism_emails(apr24)
    ).uniq

    apr24_emails = metabolism_emails(apr24)

    last_orders_raw = ShoplineOrder
      .where(METABOLISM)
      .where(email: all_prev_emails)
      .where(order_date: jul4.first..apr24.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    last_orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts  = ShoplineOrder.where(METABOLISM).where(email: all_prev_emails).group(:email).count
    history_amounts = ShoplineOrder.where(METABOLISM).where(email: all_prev_emails).group(:email).sum(:total_amount)

    today = Date.today

    customers = ShoplineCustomer
      .where(email: all_prev_emails)
      .select(:id, :full_name, :email, :membership_level, :instagram_account, :shopline_id, :mobile_phone)

    rows = customers.map do |c|
      last          = last_order_by_email[c.email]
      bottles       = extract_bottles(last&.dig(:product_name))
      last_date     = last&.dig(:order_date)&.to_date
      expected_days = bottles * DAYS_PER_BOTTLE
      overdue_days  = last_date ? (today - last_date).to_i - expected_days : nil
      returned      = apr24_emails.include?(c.email)

      status = if returned
                 "✅ 4/24 已回購"
               elsif overdue_days.nil? || overdue_days > 0
                 "❗ 已吃完未回購"
               elsif overdue_days >= -14
                 "⏰ 14天內吃完"
               else
                 "📺 邀請看直播"
               end

      {
        customer:       c,
        last_date:      last_date,
        bottles:        bottles,
        overdue_days:   overdue_days,
        status:         status,
        returned:       returned,
        history_count:  history_counts[c.email]  || 0,
        history_amount: history_amounts[c.email] || 0
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), r[:returned] ? 1 : 0, -r[:history_count]] }

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["狀態", "姓名", "卡別", "電話", "Email", "IG帳號",
              "上次購買", "瓶數", "逾期天數", "歷史購買次數", "歷史消費金額", "Shopline 連結"]
      rows.each do |r|
        c = r[:customer]
        csv << [
          r[:status],
          c.full_name,
          c.membership_level,
          c.mobile_phone,
          c.email,
          c.instagram_account,
          r[:last_date]&.strftime("%Y/%m/%d"),
          r[:bottles],
          r[:overdue_days],
          r[:history_count],
          r[:history_amount]&.to_i || 0,
          "https://admin.shoplineapp.com/admin/yardley/users/#{c.shopline_id}"
        ]
      end
    end

    send_data "\xEF\xBB\xBF#{csv_data}",
              filename: "代謝錠五場分析_#{Date.today.strftime('%Y%m%d')}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def copurchase_products
    metabolism_order_numbers = ShoplineOrder
      .where(METABOLISM)
      .where.not(order_number: [nil, ""])
      .distinct
      .pluck(:order_number)

    ShoplineOrder
      .where(order_number: metabolism_order_numbers)
      .where.not("product_name LIKE '%代謝%'")
      .where.not(product_name: [nil, ""])
      .group(:product_name)
      .order("count_all DESC")
      .limit(10)
      .count
  end

  def metabolism_emails(range)
    ShoplineOrder
      .where(METABOLISM)
      .where(order_date: range)
      .where.not(email: [nil, ""])
      .distinct
      .pluck(:email)
  end

  def top_products(range)
    ShoplineOrder
      .where(METABOLISM)
      .where(order_date: range)
      .group(:product_name)
      .order("count_all DESC")
      .limit(3)
      .count
  end

  def event_revenue(range)
    ShoplineOrder
      .where(METABOLISM)
      .where(order_date: range)
      .where.not(total_amount: nil)
      .sum(:total_amount)
      .to_i
  end

  def event_aov(range)
    orders = ShoplineOrder
      .where(METABOLISM)
      .where(order_date: range)
      .where.not(total_amount: nil)
    return 0 if orders.empty?
    total       = orders.sum(:total_amount)
    uniq_orders = orders.select(:order_number).distinct.count
    return 0 if uniq_orders.zero?
    (total / uniq_orders).round(0).to_i
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(/代謝錠(\d+)/)
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
