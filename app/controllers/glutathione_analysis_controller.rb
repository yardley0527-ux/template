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

  EVENT_RANGE = Date.new(2026, 1, 22).beginning_of_day..Date.new(2026, 1, 24).end_of_day

  before_action :build_analysis_data, only: [:index, :export_missing, :export_jan23]

  def index; end

  def export_missing
    send_data "\xEF\xBB\xBF" + missing_csv,
              filename: "穀胱甘肽_未回購名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  def export_jan23
    send_data "\xEF\xBB\xBF" + jan23_csv,
              filename: "穀胱甘肽_1月23日購買名單_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_analysis_data
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

    # Per-level attendance stats
    @level_stats = TARGET_MEMBERSHIPS.filter_map do |level|
      total = ShoplineCustomer.where(membership_level: level).where.not(shopline_id: nil).count
      next if total.zero?
      emails   = ShoplineCustomer.where(membership_level: level).where.not(email: [nil, ""]).pluck(:email)
      attended = (emails & @jan23_emails).size
      { level: level, total: total, attended: attended, rate: pct(attended, total) }
    end

    # Backward-compat vars used by insights
    black_stat        = @level_stats.find { |s| s[:level] == "黑卡" } || {}
    gold_stat         = @level_stats.find { |s| s[:level] == "金卡" } || {}
    @black_jan23_rate = black_stat[:rate].to_f
    @gold_jan23_rate  = gold_stat[:rate].to_f

    # ── 曾買、1/23 未出現 ────────────────────────────────────────────────────
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

    # ── 1/23 購買名單（所有卡別）────────────────────────────────────────────
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
    @insights << { type: :danger, text: "有 #{overdue_count} 位客人逾期超過 14 天未回購，建議立即聯繫。" } if overdue_count > 0

    black_missing = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
    @insights << { type: :danger, text: "#{black_missing} 位黑卡客人曾購買穀胱甘肽但 1/23 未出現，流失風險最高，請優先追蹤。" } if black_missing > 0

    if @jan23_customers.any?
      black_count = @jan23_customers.count { |r| r[:customer].membership_level == "黑卡" }
      gold_count  = @jan23_customers.count { |r| r[:customer].membership_level == "金卡" }
      @insights << { type: :success, text: "#{@jan23_customers.size} 位會員在 1/23 購買穀胱甘肽（黑卡 #{black_count} 人、金卡 #{gold_count} 人）。" }
    end

    @insights << { type: :info, text: "本場穀胱甘肽直播共吸引 #{@jan23_emails.size} 位不重複買家。" }
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

  def jan23_csv
    require "csv"
    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "電話", "購買品項", "瓶數", "歷史次數", "歷史消費(NT$)", "IG"]
      @jan23_customers.each do |r|
        c = r[:customer]
        csv << [c.full_name, c.membership_level, c.mobile_phone,
                r[:last_product], r[:bottles], r[:history_count], r[:history_amount].to_i, c.instagram_account]
      end
    end
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
