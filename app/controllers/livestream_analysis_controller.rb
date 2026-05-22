# frozen_string_literal: true

class LivestreamAnalysisController < ApplicationController
  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  ALL_LEVELS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze

  # 資料來自 Shopline 品牌之夜匯出報表
  EVENTS_2026 = [
    {
      date: Date.new(2026,  1,  9), label: "1/9",  note: "代謝+膠原、薑黃",
      orders: 129, revenue: 1_452_573,
      levels: { "黑卡" => { n: 30, amt: 400_489 }, "金卡" => { n: 34, amt: 378_144 },
                "銀卡" => { n: 23, amt: 255_598 }, "白卡" => { n: 27, amt: 309_208 }, "一般會員" => { n: 12, amt:  86_784 } }
    },
    {
      date: Date.new(2026,  1, 23), label: "1/23", note: "穀胱甘肽",
      orders: 161, revenue: 1_908_734,
      levels: { "黑卡" => { n: 34, amt: 556_675 }, "金卡" => { n: 36, amt: 436_355 },
                "銀卡" => { n: 36, amt: 384_426 }, "白卡" => { n: 32, amt: 320_968 }, "一般會員" => { n: 16, amt: 139_988 } }
    },
    {
      date: Date.new(2026,  2,  6), label: "2/6",  note: "益生菌",
      orders:  67, revenue:   905_036,
      levels: { "黑卡" => { n: 22, amt: 329_315 }, "金卡" => { n: 18, amt: 246_355 },
                "銀卡" => { n: 12, amt: 150_859 }, "白卡" => { n: 11, amt: 148_722 }, "一般會員" => { n:  3, amt:  25_885 } }
    },
    {
      date: Date.new(2026,  2, 25), label: "2/25", note: "薑黃、清纖粉、代謝",
      orders: 173, revenue: 1_391_860,
      levels: { "黑卡" => { n: 15, amt: 311_869 }, "金卡" => { n: 16, amt: 282_473 },
                "銀卡" => { n: 20, amt: 259_763 }, "白卡" => { n: 20, amt: 354_786 }, "一般會員" => { n: 10, amt:  96_403 } }
    },
    {
      date: Date.new(2026,  3,  5), label: "3/5",  note: "膠原、益生菌",
      orders:  86, revenue: 1_034_106,
      levels: { "黑卡" => { n: 14, amt: 184_053 }, "金卡" => { n: 22, amt: 247_930 },
                "銀卡" => { n: 24, amt: 300_101 }, "白卡" => { n: 18, amt: 207_252 }, "一般會員" => { n:  6, amt:  60_210 } }
    },
    {
      date: Date.new(2026,  3, 20), label: "3/20", note: "全能、私密粉、益生菌",
      orders: 208, revenue: 3_480_382,
      levels: { "黑卡" => { n: 48, amt: 1_393_108 }, "金卡" => { n: 57, amt: 931_457 },
                "銀卡" => { n: 30, amt:   458_031 }, "白卡" => { n: 26, amt: 302_522 }, "一般會員" => { n: 18, amt:  99_959 } }
    },
    {
      date: Date.new(2026,  3, 27), label: "3/27", note: "魚油、蝦紅素、維DK鈣",
      orders:  70, revenue:   470_191,
      levels: { "黑卡" => { n:  8, amt: 112_523 }, "金卡" => { n: 18, amt: 135_000 },
                "銀卡" => { n:  9, amt:  63_300 }, "白卡" => { n: 15, amt:  70_966 }, "一般會員" => { n: 14, amt:  63_193 } }
    },
    {
      date: Date.new(2026,  4, 10), label: "4/10", note: "薑黃",
      orders: 103, revenue: 1_505_901,
      levels: { "黑卡" => { n: 18, amt: 296_147 }, "金卡" => { n: 26, amt: 408_476 },
                "銀卡" => { n: 20, amt: 331_295 }, "白卡" => { n: 21, amt: 295_933 }, "一般會員" => { n: 15, amt: 116_050 } }
    },
    {
      date: Date.new(2026,  4, 24), label: "4/24", note: "代謝錠、薑黃",
      orders:  77, revenue:   676_698,
      levels: { "黑卡" => { n: 11, amt: 144_600 }, "金卡" => { n: 11, amt: 142_827 },
                "銀卡" => { n: 13, amt: 166_843 }, "白卡" => { n: 18, amt: 166_280 }, "一般會員" => { n: 10, amt:  48_668 } }
    },
    {
      date: Date.new(2026,  5,  8), label: "5/8",  note: "蝦紅素、維DK鈣、薑黃",
      orders:  70, revenue:   633_562,
      levels: { "黑卡" => { n: 17, amt: 215_535 }, "金卡" => { n: 21, amt: 138_770 },
                "銀卡" => { n: 11, amt:  82_124 }, "白卡" => { n: 11, amt: 118_123 }, "一般會員" => { n:  7, amt:  47_680 } }
    },
  ].freeze

  WINDOW_DAYS = 1  # 活動日 ±1 天視窗

  def index
    today = Date.today
    past_events = EVENTS_2026.select { |e| e[:date] <= today }
    return (@events_data = []) if past_events.empty?

    # 每場從 DB 撈出席 email（有匯入資料的場次才有值）
    @events_data = past_events.map do |event|
      range = event[:date].beginning_of_day..(event[:date] + WINDOW_DAYS).end_of_day
      db_emails = ShoplineOrder
        .where(order_date: range)
        .where.not(email: [nil, ""])
        .distinct.pluck(:email)
      event.merge(db_emails: db_emails)
    end

    @latest = @events_data.last

    # 連場回流率（只計算 DB 兩邊都有資料的相鄰場次）
    @return_rates = []
    @events_data.each_cons(2) do |prev, curr|
      next if prev[:db_emails].empty? || curr[:db_emails].empty?
      overlap = (prev[:db_emails] & curr[:db_emails]).size
      @return_rates << {
        from: prev[:label], to: curr[:label],
        count: overlap, from_total: prev[:db_emails].size,
        rate: pct(overlap, prev[:db_emails].size)
      }
    end

    # 最近 N 場都有 DB 資料的場次（用於客戶追蹤）
    db_events = @events_data.select { |e| e[:db_emails].any? }

    if db_events.size >= 2
      lookback      = db_events[-[4, db_events.size].min..-2]
      prev_emails   = lookback.flat_map { |e| e[:db_emails] }.uniq
      missing_emails = prev_emails - db_events.last[:db_emails]

      customers_map = ShoplineCustomer
        .where(email: missing_emails)
        .index_by(&:email)

      @missing_customers = missing_emails.filter_map do |email|
        c = customers_map[email]
        next unless c
        appeared_in = lookback.select { |e| e[:db_emails].include?(email) }.map { |e| e[:label] }
        {
          customer: c,
          appeared_in: appeared_in,
          appeared_count: appeared_in.size
        }
      end.sort_by { |r|
        [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0),
         -r[:appeared_count],
         -r[:customer].total_amount.to_f]
      }
    else
      @missing_customers = []
    end

    # 忠實客：最近 3 場（有 DB 資料）
    if db_events.size >= 3
      last3          = db_events.last(3)
      loyal_3_emails = last3.map { |e| e[:db_emails] }.reduce(:&)
      loyal_2_emails = last3.combination(2)
                            .flat_map { |a, b| a[:db_emails] & b[:db_emails] }
                            .uniq - loyal_3_emails

      @loyal_3_customers = build_loyal_customers(loyal_3_emails, last3)
      @loyal_2_customers = build_loyal_customers(loyal_2_emails, last3)
    else
      @loyal_3_customers = []
      @loyal_2_customers = []
    end

    # 各卡別總人數（出席率分母）
    @level_totals = ALL_LEVELS.index_with do |level|
      ShoplineCustomer.where(membership_level: level).count
    end

    build_insights
  end

  private

  def build_loyal_customers(emails, recent_events)
    return [] if emails.empty?

    ShoplineCustomer
      .where(email: emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map do |c|
        attended = recent_events.select { |e| e[:db_emails].include?(c.email) }.map { |e| e[:label] }
        { customer: c, attended_labels: attended }
      end
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
  end

  def build_insights
    @insights = []
    return if @events_data.size < 2

    latest = @events_data.last
    prev   = @events_data[-2]

    # 營業額趨勢
    if latest[:revenue] > prev[:revenue]
      chg = ((latest[:revenue].to_f / prev[:revenue] - 1) * 100).round(0)
      @insights << { type: :success, text: "#{latest[:label]} 場次營業額較 #{prev[:label]} 成長 #{chg}%（NT$#{ActiveSupport::NumberHelper.number_to_delimited(latest[:revenue])}）。" }
    else
      chg = ((1 - latest[:revenue].to_f / prev[:revenue]) * 100).round(0)
      @insights << { type: :warning, text: "#{latest[:label]} 場次營業額較 #{prev[:label]} 下滑 #{chg}%（NT$#{ActiveSupport::NumberHelper.number_to_delimited(latest[:revenue])}）。" }
    end

    # 貢獻最高卡別
    top_level, top_data = latest[:levels].max_by { |_, v| v[:amt] }
    @insights << { type: :info, text: "#{latest[:label]} 場次 #{top_level} 貢獻最高，#{top_data[:n]} 人，消費 NT$#{ActiveSupport::NumberHelper.number_to_delimited(top_data[:amt])}。" }

    # 連場回流率
    if @return_rates.any?
      rr = @return_rates.last
      if rr[:rate] >= 30
        @insights << { type: :success, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），黏著度良好。" }
      else
        @insights << { type: :warning, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），建議直播前 2 天主動通知。" }
      end
    end

    # 未出席
    if @missing_customers.any?
      black_n = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
      suffix  = black_n > 0 ? "，其中 #{black_n} 位黑卡請優先聯繫" : ""
      @insights << { type: :danger, text: "#{@missing_customers.size} 位近期曾出席的客人 #{latest[:label]} 未出現#{suffix}。" }
    end

    @insights << { type: :success, text: "#{@loyal_3_customers.size} 位客人最近三場全勤，是核心忠實客，適合邀請為品牌大使。" } if @loyal_3_customers.size > 0
    @insights << { type: :info,    text: "#{@loyal_2_customers.size} 位客人近三場出席兩場，下場直播前建議主動通知。" } if @loyal_2_customers.size > 0
  end

  def pct(num, den)
    return 0.0 if den.zero?
    (num.to_f / den * 100).round(1)
  end
end
