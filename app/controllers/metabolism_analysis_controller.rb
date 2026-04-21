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

  def index
    jul4  = Date.new(2025,  7,  3).beginning_of_day..Date.new(2025,  7,  5).end_of_day
    jul22 = Date.new(2025,  7, 21).beginning_of_day..Date.new(2025,  7, 23).end_of_day
    oct9  = Date.new(2025, 10,  8).beginning_of_day..Date.new(2025, 10, 11).end_of_day
    feb25 = Date.new(2026,  2, 24).beginning_of_day..Date.new(2026,  2, 26).end_of_day

    @jul4_emails  = metabolism_emails(jul4)
    @jul22_emails = metabolism_emails(jul22)
    @oct9_emails  = metabolism_emails(oct9)
    @feb25_emails = metabolism_emails(feb25)

    @jul4_to_jul22_count = (@jul4_emails  & @jul22_emails).size
    @jul22_to_oct9_count = (@jul22_emails & @oct9_emails).size
    @oct9_to_feb25_count = (@oct9_emails  & @feb25_emails).size
    @all_prev_emails     = (@jul4_emails | @jul22_emails | @oct9_emails | @feb25_emails).uniq

    @jul4_return_rate  = pct(@jul4_to_jul22_count, @jul4_emails.size)
    @jul22_return_rate = pct(@jul22_to_oct9_count, @jul22_emails.size)
    @oct9_return_rate  = pct(@oct9_to_feb25_count, @oct9_emails.size)

    prev_3_emails     = (@jul4_emails | @jul22_emails | @oct9_emails).uniq
    @prev_return_rate = pct((prev_3_emails & @feb25_emails).size, prev_3_emails.size)

    black_emails = ShoplineCustomer.where(membership_level: "黑卡").where.not(email: [nil, ""]).pluck(:email)
    gold_emails  = ShoplineCustomer.where(membership_level: "金卡").where.not(email: [nil, ""]).pluck(:email)

    @black_card_total = ShoplineCustomer.where(membership_level: "黑卡").where.not(shopline_id: nil).count
    @gold_card_total  = ShoplineCustomer.where(membership_level: "金卡").where.not(shopline_id: nil).count

    @black_jul4  = (black_emails & @jul4_emails).size
    @black_jul22 = (black_emails & @jul22_emails).size
    @black_oct9  = (black_emails & @oct9_emails).size
    @black_feb25 = (black_emails & @feb25_emails).size

    @gold_jul4   = (gold_emails & @jul4_emails).size
    @gold_jul22  = (gold_emails & @jul22_emails).size
    @gold_oct9   = (gold_emails & @oct9_emails).size
    @gold_feb25  = (gold_emails & @feb25_emails).size

    @black_jul4_rate  = pct(@black_jul4,  @black_card_total)
    @black_jul22_rate = pct(@black_jul22, @black_card_total)
    @black_oct9_rate  = pct(@black_oct9,  @black_card_total)
    @black_feb25_rate = pct(@black_feb25, @black_card_total)
    @gold_jul4_rate   = pct(@gold_jul4,   @gold_card_total)
    @gold_jul22_rate  = pct(@gold_jul22,  @gold_card_total)
    @gold_oct9_rate   = pct(@gold_oct9,   @gold_card_total)
    @gold_feb25_rate  = pct(@gold_feb25,  @gold_card_total)

    # 各場數據
    @jul4_top_products  = top_products(jul4)
    @jul22_top_products = top_products(jul22)
    @oct9_top_products  = top_products(oct9)
    @feb25_top_products = top_products(feb25)

    @jul4_revenue  = event_revenue(jul4)
    @jul22_revenue = event_revenue(jul22)
    @oct9_revenue  = event_revenue(oct9)
    @feb25_revenue = event_revenue(feb25)

    @jul4_aov  = event_aov(jul4)
    @jul22_aov = event_aov(jul22)
    @oct9_aov  = event_aov(oct9)
    @feb25_aov = event_aov(feb25)
    @copurchase_products = copurchase_products

    last_orders_raw = ShoplineOrder
      .where(METABOLISM)
      .where(email: @all_prev_emails)
      .where(order_date: jul4.first..feb25.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    last_orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts  = ShoplineOrder.where(METABOLISM).where(email: @all_prev_emails).group(:email).count
    history_amounts = ShoplineOrder.where(METABOLISM).where(email: @all_prev_emails).group(:email).sum(:total_amount)

    customers = ShoplineCustomer
      .where(membership_level: TARGET_MEMBERSHIPS)
      .where(email: @all_prev_emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)

    today = Date.today

    all_customers = customers.map do |c|
      last            = last_order_by_email[c.email]
      bottles         = extract_bottles(last&.dig(:product_name))
      last_date       = last&.dig(:order_date)&.to_date
      expected_days   = bottles * DAYS_PER_BOTTLE
      overdue_days    = last_date ? (today - last_date).to_i - expected_days : nil
      history_count   = history_counts[c.email]  || 0
      history_amount  = history_amounts[c.email] || 0

      {
        customer:       c,
        last_product:   last&.dig(:product_name),
        last_date:      last_date,
        bottles:        bottles,
        expected_days:  expected_days,
        overdue_days:   overdue_days,
        history_count:  history_count,
        history_amount: history_amount,
        attended_jul4:  @jul4_emails.include?(c.email),
        attended_jul22: @jul22_emails.include?(c.email),
        attended_oct9:  @oct9_emails.include?(c.email),
        attended_feb25: @feb25_emails.include?(c.email)
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_count], -r[:history_amount].to_f] }

    @overdue_customers = all_customers.select { |r| r[:overdue_days].nil? || r[:overdue_days] > 0 }
    @not_due_customers = all_customers.select { |r| r[:overdue_days] && r[:overdue_days] <= 0 }

    # 14 天內即將吃完（還沒到期，但快了）— 全會員等級
    all_emails_for_alert = @all_prev_emails

    last_orders_all_raw = ShoplineOrder
      .where(METABOLISM)
      .where(email: all_emails_for_alert)
      .where(order_date: jul4.first..feb25.last)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_all_by_email = {}
    last_orders_all_raw.each do |email, product_name, order_date|
      last_order_all_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    history_counts_all  = ShoplineOrder.where(METABOLISM).where(email: all_emails_for_alert).group(:email).count
    history_amounts_all = ShoplineOrder.where(METABOLISM).where(email: all_emails_for_alert).group(:email).sum(:total_amount)

    all_customers_for_alert = ShoplineCustomer
      .where(email: all_emails_for_alert)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account)
      .map do |c|
        last          = last_order_all_by_email[c.email]
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
          history_count:  history_counts_all[c.email]  || 0,
          history_amount: history_amounts_all[c.email] || 0
        }
      end

    # 14 天內即將吃完（overdue_days 在 -14 ~ 0 之間，還沒過期但快了）
    @expiring_soon = all_customers_for_alert
    .select { |r| r[:overdue_days] && r[:overdue_days] >= -14 && r[:overdue_days] <= 0 }
    .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), r[:overdue_days].to_i] }

    loyal_4_emails = @jul4_emails & @jul22_emails & @oct9_emails & @feb25_emails

    loyal_3_emails = (
      (@jul4_emails  & @jul22_emails & @oct9_emails)  |
      (@jul4_emails  & @jul22_emails & @feb25_emails) |
      (@jul4_emails  & @oct9_emails  & @feb25_emails) |
      (@jul22_emails & @oct9_emails  & @feb25_emails)
    ).uniq - loyal_4_emails

    loyal_2_emails = (
      (@jul4_emails  & @jul22_emails) |
      (@jul4_emails  & @oct9_emails)  |
      (@jul4_emails  & @feb25_emails) |
      (@jul22_emails & @oct9_emails)  |
      (@jul22_emails & @feb25_emails) |
      (@oct9_emails  & @feb25_emails)
    ).uniq - loyal_4_emails - loyal_3_emails

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

    @loyal_4_customers = build_loyal.call(loyal_4_emails)
    @loyal_3_customers = build_loyal.call(loyal_3_emails)
    @loyal_2_customers = build_loyal.call(loyal_2_emails)

    @insights = []

    overdue_count = @overdue_customers.count { |r| r[:overdue_days] && r[:overdue_days] > 14 }
    @insights << { type: :danger, text: "有 #{overdue_count} 位金卡以上客人逾期超過 14 天未回購代謝錠，建議 4/24 前主動聯繫邀請。" } if overdue_count > 0

    black_count = (all_customers).count { |r| r[:customer].membership_level == "黑卡" }
    @insights << { type: :danger, text: "#{black_count} 位黑卡客人曾購買代謝錠，4/24 前務必一對一提醒。" } if black_count > 0

    rates = [@jul4_return_rate, @jul22_return_rate, @oct9_return_rate]
    if rates.each_cons(2).all? { |a, b| b >= a }
      @insights << { type: :success, text: "回購率呈上升趨勢（7/4→7/22 #{@jul4_return_rate}%，7/22→10/9 #{@jul22_return_rate}%，10/9→2/25 #{@oct9_return_rate}%），代謝錠客群忠誠度持續成長。" }
    else
      @insights << { type: :warning, text: "連場回購率：7/4→7/22 #{@jul4_return_rate}%，7/22→10/9 #{@jul22_return_rate}%，10/9→2/25 #{@oct9_return_rate}%，4/24 前建議加強暖場通知。" }
    end

    @insights << { type: :info,    text: "曾買過代謝錠的客人整體回流率為 #{@prev_return_rate}%（前三場 → 2/25）。" }
    @insights << { type: :success, text: "#{@loyal_4_customers.size} 位客人四場都有購買代謝錠，是最核心的忠實客，建議邀請成為品牌大使或提供 VIP 專屬優惠。" } if @loyal_4_customers.size > 0
    @insights << { type: :success, text: "#{@loyal_3_customers.size} 位客人任意三場有購買，高忠誠度客群，4/24 前優先提醒。" } if @loyal_3_customers.size > 0
    @insights << { type: :info,    text: "#{@loyal_2_customers.size} 位客人任意兩場有購買，具穩定回購習慣，4/24 前 3 天建議主動通知。" } if @loyal_2_customers.size > 0
    @insights << { type: :info,    text: "累計 #{@all_prev_emails.size} 位不重複客人曾在四場購買代謝錠，可作為 4/24 邀請名單基礎。" }
  end

  def export
    jul4  = Date.new(2025,  7,  3).beginning_of_day..Date.new(2025,  7,  5).end_of_day
    jul22 = Date.new(2025,  7, 21).beginning_of_day..Date.new(2025,  7, 23).end_of_day
    oct9  = Date.new(2025, 10,  8).beginning_of_day..Date.new(2025, 10, 11).end_of_day
    feb25 = Date.new(2026,  2, 24).beginning_of_day..Date.new(2026,  2, 26).end_of_day

    all_prev_emails = (
      metabolism_emails(jul4) |
      metabolism_emails(jul22) |
      metabolism_emails(oct9) |
      metabolism_emails(feb25)
    ).uniq

    history_counts  = ShoplineOrder.where(METABOLISM).where(email: all_prev_emails).group(:email).count
    history_amounts = ShoplineOrder.where(METABOLISM).where(email: all_prev_emails).group(:email).sum(:total_amount)

    # ✅ 改成全部等級
    customers = ShoplineCustomer
      .where(email: all_prev_emails)
      .select(:id, :full_name, :email, :membership_level, :instagram_account, :shopline_id)
      .sort_by { |c| [-MEMBERSHIP_RANK.fetch(c.membership_level, 0), -(history_counts[c.email] || 0), -(history_amounts[c.email] || 0).to_f] }

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "Email", "IG帳號", "歷史購買次數", "歷史消費金額", "Shopline 客人連結"]
      customers.each do |c|
        sl_url = "https://admin.shoplineapp.com/admin/yardley/users/#{c.shopline_id}"
        csv << [
          c.full_name,
          c.membership_level,
          c.email,
          c.instagram_account,
          history_counts[c.email] || 0,
          history_amounts[c.email]&.to_i || 0,
          sl_url
        ]
      end
    end

    send_data "\xEF\xBB\xBF#{csv_data}",
              filename: "代謝錠品牌之夜邀請名單_#{Date.today.strftime('%Y%m%d')}.csv",
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
    total   = orders.sum(:total_amount)
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