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

  # 2024 場次（8/9 ~ 12/23，部分無營業額資料）
  EVENTS_2024 = [
    { date: Date.new(2024,  8,  9), label: "8/9",   year: 2024, note: "B群+C鋅鎂、薑黃、代謝",
      orders: 127, revenue: 0,
      levels: { "黑卡" => { n:  0, amt: nil }, "金卡" => { n:  8, amt: nil }, "銀卡" => { n: 19, amt: nil }, "白卡" => { n: 32, amt: nil }, "一般會員" => { n: 23, amt: nil } } },
    { date: Date.new(2024,  9, 13), label: "9/13",  year: 2024, note: "NMN白藜蘆醇",
      orders: 315, revenue: 2_992_194,
      levels: { "黑卡" => { n:  3, amt: nil }, "金卡" => { n: 41, amt: nil }, "銀卡" => { n: 80, amt: nil }, "白卡" => { n: 77, amt: nil }, "一般會員" => { n: 37, amt: nil } } },
    { date: Date.new(2024, 10, 14), label: "10/14", year: 2024, note: "B群+C鋅鎂",
      orders: 245, revenue: 0,
      levels: { "黑卡" => { n:  0, amt: nil }, "金卡" => { n: 19, amt: nil }, "銀卡" => { n: 45, amt: nil }, "白卡" => { n: 79, amt: nil }, "一般會員" => { n: 56, amt: nil } } },
    { date: Date.new(2024, 11,  8), label: "11/8",  year: 2024, note: "雙11套組",
      orders: 280, revenue: 0,
      levels: { "黑卡" => { n:  1, amt: nil }, "金卡" => { n: 20, amt: nil }, "銀卡" => { n: 60, amt: nil }, "白卡" => { n: 90, amt: nil }, "一般會員" => { n: 63, amt: nil } } },
    { date: Date.new(2024, 11, 22), label: "11/22", year: 2024, note: "代謝錠",
      orders: 312, revenue: 0,
      levels: { "黑卡" => { n:  1, amt: nil }, "金卡" => { n: 27, amt: nil }, "銀卡" => { n: 62, amt: nil }, "白卡" => { n: 104, amt: nil }, "一般會員" => { n: 85, amt: nil } } },
    { date: Date.new(2024, 12, 13), label: "12/13", year: 2024, note: "薑黃",
      orders: 323, revenue: 0,
      levels: { "黑卡" => { n:  0, amt: nil }, "金卡" => { n: 24, amt: nil }, "銀卡" => { n: 58, amt: nil }, "白卡" => { n: 82, amt: nil }, "一般會員" => { n: 124, amt: nil } } },
    { date: Date.new(2024, 12, 23), label: "12/23", year: 2024, note: "NMN白藜蘆醇",
      orders: 134, revenue: 1_045_098,
      levels: { "黑卡" => { n:  0, amt: nil }, "金卡" => { n: 16, amt: nil }, "銀卡" => { n: 27, amt: nil }, "白卡" => { n: 60, amt: nil }, "一般會員" => { n: 21, amt: nil } } },
  ].freeze

  # 2025 場次（1/5 ~ 12/24）
  EVENTS_2025 = [
    { date: Date.new(2025,  1,  5), label: "1/5",   year: 2025, note: "膠原飲",
      orders: 626, revenue: 5_229_296,
      levels: { "黑卡" => { n:  8, amt: nil }, "金卡" => { n: 60, amt: nil }, "銀卡" => { n: 100, amt: nil }, "白卡" => { n: 171, amt: nil }, "一般會員" => { n: 222, amt: nil } } },
    { date: Date.new(2025,  1, 13), label: "1/13",  year: 2025, note: "V-Lift美容儀",
      orders: 531, revenue: 0,
      levels: { "黑卡" => { n:  8, amt: nil }, "金卡" => { n: 67, amt: nil }, "銀卡" => { n: 126, amt: nil }, "白卡" => { n: 147, amt: nil }, "一般會員" => { n: 86, amt: nil } } },
    { date: Date.new(2025,  2, 20), label: "2/20",  year: 2025, note: "NMN+膠原",
      orders: 134, revenue: 806_262,
      levels: { "黑卡" => { n:  4, amt: nil }, "金卡" => { n: 17, amt: nil }, "銀卡" => { n: 20, amt: nil }, "白卡" => { n: 35, amt: nil }, "一般會員" => { n: 46, amt: nil } } },
    { date: Date.new(2025,  3, 10), label: "3/10",  year: 2025, note: "薑黃+B群",
      orders: 209, revenue: 1_329_698,
      levels: { "黑卡" => { n:  6, amt: nil }, "金卡" => { n: 31, amt: nil }, "銀卡" => { n: 45, amt: nil }, "白卡" => { n: 56, amt: nil }, "一般會員" => { n: 55, amt: nil } } },
    { date: Date.new(2025,  3, 21), label: "3/21",  year: 2025, note: "蝦紅素",
      orders: 225, revenue: 1_783_597,
      levels: { "黑卡" => { n: 10, amt: nil }, "金卡" => { n: 36, amt: nil }, "銀卡" => { n: 54, amt: nil }, "白卡" => { n: 66, amt: nil }, "一般會員" => { n: 32, amt: nil } } },
    { date: Date.new(2025,  4, 11), label: "4/11",  year: 2025, note: "膠原飲",
      orders: 391, revenue: 5_909_289,
      levels: { "黑卡" => { n: 15, amt: nil }, "金卡" => { n: 56, amt: nil }, "銀卡" => { n: 71, amt: nil }, "白卡" => { n: 107, amt: nil }, "一般會員" => { n: 104, amt: nil } } },
    { date: Date.new(2025,  4, 22), label: "4/22",  year: 2025, note: "代謝錠",
      orders: 415, revenue: 4_243_944,
      levels: { "黑卡" => { n: 20, amt: nil }, "金卡" => { n: 64, amt: nil }, "銀卡" => { n: 108, amt: nil }, "白卡" => { n: 92, amt: nil }, "一般會員" => { n: 68, amt: nil } } },
    { date: Date.new(2025,  5,  9), label: "5/9",   year: 2025, note: "B群+C鋅鎂",
      orders: 215, revenue: 2_602_549,
      levels: { "黑卡" => { n: 28, amt: nil }, "金卡" => { n: 48, amt: nil }, "銀卡" => { n: 56, amt: nil }, "白卡" => { n: 52, amt: nil }, "一般會員" => { n: 17, amt: nil } } },
    { date: Date.new(2025,  5, 20), label: "5/20",  year: 2025, note: "蝦紅素",
      orders: 108, revenue: 1_004_215,
      levels: { "黑卡" => { n: 12, amt: nil }, "金卡" => { n: 19, amt: nil }, "銀卡" => { n: 24, amt: nil }, "白卡" => { n: 33, amt: nil }, "一般會員" => { n: 17, amt: nil } } },
    { date: Date.new(2025,  6,  9), label: "6/9",   year: 2025, note: "NMN白藜蘆醇",
      orders:  99, revenue: 1_150_864,
      levels: { "黑卡" => { n: 15, amt: nil }, "金卡" => { n: 16, amt: nil }, "銀卡" => { n: 28, amt: nil }, "白卡" => { n: 21, amt: nil }, "一般會員" => { n: 11, amt: nil } } },
    { date: Date.new(2025,  6, 20), label: "6/20",  year: 2025, note: "魚油",
      orders: 164, revenue: 1_615_396,
      levels: { "黑卡" => { n: 32, amt: nil }, "金卡" => { n: 40, amt: nil }, "銀卡" => { n: 43, amt: nil }, "白卡" => { n: 32, amt: nil }, "一般會員" => { n: 11, amt: nil } } },
    { date: Date.new(2025,  7,  4), label: "7/4",   year: 2025, note: "薑黃+代謝",
      orders: 130, revenue: 1_248_037,
      levels: { "黑卡" => { n: 11, amt: nil }, "金卡" => { n: 26, amt: nil }, "銀卡" => { n: 25, amt: nil }, "白卡" => { n: 22, amt: nil }, "一般會員" => { n: 24, amt: nil } } },
    { date: Date.new(2025,  7, 22), label: "7/22",  year: 2025, note: "薑黃+代謝",
      orders:  86, revenue: 697_312,
      levels: { "黑卡" => { n:  5, amt: nil }, "金卡" => { n: 12, amt: nil }, "銀卡" => { n: 18, amt: nil }, "白卡" => { n: 18, amt: nil }, "一般會員" => { n: 16, amt: nil } } },
    { date: Date.new(2025,  8,  4), label: "8/4",   year: 2025, note: "清纖粉+面膜",
      orders: 234, revenue: 2_341_288,
      levels: { "黑卡" => { n: 31, amt: nil }, "金卡" => { n: 50, amt: nil }, "銀卡" => { n: 48, amt: nil }, "白卡" => { n: 60, amt: nil }, "一般會員" => { n: 34, amt: nil } } },
    { date: Date.new(2025,  8, 21), label: "8/21",  year: 2025, note: "膠原飲",
      orders: 108, revenue: 1_327_230,
      levels: { "黑卡" => { n: 14, amt: nil }, "金卡" => { n: 17, amt: nil }, "銀卡" => { n: 23, amt: nil }, "白卡" => { n: 19, amt: nil }, "一般會員" => { n: 10, amt: nil } } },
    { date: Date.new(2025,  9,  4), label: "9/4",   year: 2025, note: "B群+NMN",
      orders: 129, revenue: 1_559_607,
      levels: { "黑卡" => { n: 24, amt: nil }, "金卡" => { n: 33, amt: nil }, "銀卡" => { n: 28, amt: nil }, "白卡" => { n: 17, amt: nil }, "一般會員" => { n: 20, amt: nil } } },
    { date: Date.new(2025,  9, 15), label: "9/15",  year: 2025, note: "私密粉",
      orders: 107, revenue: 966_143,
      levels: { "黑卡" => { n: 27, amt: nil }, "金卡" => { n: 33, amt: nil }, "銀卡" => { n: 29, amt: nil }, "白卡" => { n: 12, amt: nil }, "一般會員" => { n:  4, amt: nil } } },
    { date: Date.new(2025, 10,  9), label: "10/9",  year: 2025, note: "代謝錠",
      orders: 204, revenue: 2_156_712,
      levels: { "黑卡" => { n: 27, amt: nil }, "金卡" => { n: 33, amt: nil }, "銀卡" => { n: 29, amt: nil }, "白卡" => { n: 12, amt: nil }, "一般會員" => { n:  4, amt: nil } } },
    { date: Date.new(2025, 10, 20), label: "10/20", year: 2025, note: "蝦紅素",
      orders:  59, revenue: 582_696,
      levels: { "黑卡" => { n: 11, amt: nil }, "金卡" => { n: 13, amt: nil }, "銀卡" => { n: 12, amt: nil }, "白卡" => { n: 14, amt: nil }, "一般會員" => { n:  3, amt: nil } } },
    { date: Date.new(2025, 11,  7), label: "11/7",  year: 2025, note: "薑黃",
      orders: 177, revenue: 2_380_269,
      levels: { "黑卡" => { n: 37, amt: nil }, "金卡" => { n: 42, amt: nil }, "銀卡" => { n: 41, amt: nil }, "白卡" => { n: 29, amt: nil }, "一般會員" => { n: 16, amt: nil } } },
    { date: Date.new(2025, 11, 22), label: "11/22", year: 2025, note: "魚油",
      orders:  68, revenue: 1_036_397,
      levels: { "黑卡" => { n: 15, amt: nil }, "金卡" => { n: 22, amt: nil }, "銀卡" => { n: 11, amt: nil }, "白卡" => { n: 12, amt: nil }, "一般會員" => { n:  3, amt: nil } } },
    { date: Date.new(2025, 12,  7), label: "12/7",  year: 2025, note: "美白",
      orders:  53, revenue: 623_632,
      levels: { "黑卡" => { n: 11, amt: nil }, "金卡" => { n: 18, amt: nil }, "銀卡" => { n: 16, amt: nil }, "白卡" => { n:  9, amt: nil }, "一般會員" => { n:  4, amt: nil } } },
    { date: Date.new(2025, 12, 19), label: "12/19", year: 2025, note: "維DK鈣",
      orders:  82, revenue: 1_007_664,
      levels: { "黑卡" => { n: 21, amt: nil }, "金卡" => { n: 33, amt: nil }, "銀卡" => { n: 16, amt: nil }, "白卡" => { n:  6, amt: nil }, "一般會員" => { n:  3, amt: nil } } },
    { date: Date.new(2025, 12, 24), label: "12/24", year: 2025, note: "瘦身粉",
      orders:  91, revenue: 822_364,
      levels: { "黑卡" => { n: 14, amt: nil }, "金卡" => { n: 30, amt: nil }, "銀卡" => { n: 22, amt: nil }, "白卡" => { n: 17, amt: nil }, "一般會員" => { n:  4, amt: nil } } },
  ].freeze

  # 2026 場次（已有卡別消費額）
  EVENTS_2026 = [
    { date: Date.new(2026,  1,  9), label: "1/9",  year: 2026, note: "代謝+膠原、薑黃",
      orders: 129, revenue: 1_452_573,
      levels: { "黑卡" => { n: 30, amt: 400_489 }, "金卡" => { n: 34, amt: 378_144 },
                "銀卡" => { n: 23, amt: 255_598 }, "白卡" => { n: 27, amt: 309_208 }, "一般會員" => { n: 12, amt:  86_784 } } },
    { date: Date.new(2026,  1, 23), label: "1/23", year: 2026, note: "穀胱甘肽",
      orders: 161, revenue: 1_908_734,
      levels: { "黑卡" => { n: 34, amt: 556_675 }, "金卡" => { n: 36, amt: 436_355 },
                "銀卡" => { n: 36, amt: 384_426 }, "白卡" => { n: 32, amt: 320_968 }, "一般會員" => { n: 16, amt: 139_988 } } },
    { date: Date.new(2026,  2,  6), label: "2/6",  year: 2026, note: "益生菌",
      orders:  67, revenue:   905_036,
      levels: { "黑卡" => { n: 22, amt: 329_315 }, "金卡" => { n: 18, amt: 246_355 },
                "銀卡" => { n: 12, amt: 150_859 }, "白卡" => { n: 11, amt: 148_722 }, "一般會員" => { n:  3, amt:  25_885 } } },
    { date: Date.new(2026,  2, 25), label: "2/25", year: 2026, note: "薑黃、清纖粉、代謝",
      orders: 173, revenue: 1_391_860,
      levels: { "黑卡" => { n: 15, amt: 311_869 }, "金卡" => { n: 16, amt: 282_473 },
                "銀卡" => { n: 20, amt: 259_763 }, "白卡" => { n: 20, amt: 354_786 }, "一般會員" => { n: 10, amt:  96_403 } } },
    { date: Date.new(2026,  3,  5), label: "3/5",  year: 2026, note: "膠原、益生菌",
      orders:  86, revenue: 1_034_106,
      levels: { "黑卡" => { n: 14, amt: 184_053 }, "金卡" => { n: 22, amt: 247_930 },
                "銀卡" => { n: 24, amt: 300_101 }, "白卡" => { n: 18, amt: 207_252 }, "一般會員" => { n:  6, amt:  60_210 } } },
    { date: Date.new(2026,  3, 20), label: "3/20", year: 2026, note: "全能、私密粉、益生菌",
      orders: 208, revenue: 3_480_382,
      levels: { "黑卡" => { n: 48, amt: 1_393_108 }, "金卡" => { n: 57, amt: 931_457 },
                "銀卡" => { n: 30, amt:   458_031 }, "白卡" => { n: 26, amt: 302_522 }, "一般會員" => { n: 18, amt:  99_959 } } },
    { date: Date.new(2026,  3, 27), label: "3/27", year: 2026, note: "魚油、蝦紅素、維DK鈣",
      orders:  70, revenue:   470_191,
      levels: { "黑卡" => { n:  8, amt: 112_523 }, "金卡" => { n: 18, amt: 135_000 },
                "銀卡" => { n:  9, amt:  63_300 }, "白卡" => { n: 15, amt:  70_966 }, "一般會員" => { n: 14, amt:  63_193 } } },
    { date: Date.new(2026,  4, 10), label: "4/10", year: 2026, note: "薑黃",
      orders: 103, revenue: 1_505_901,
      levels: { "黑卡" => { n: 18, amt: 296_147 }, "金卡" => { n: 26, amt: 408_476 },
                "銀卡" => { n: 20, amt: 331_295 }, "白卡" => { n: 21, amt: 295_933 }, "一般會員" => { n: 15, amt: 116_050 } } },
    { date: Date.new(2026,  4, 24), label: "4/24", year: 2026, note: "代謝錠、薑黃",
      orders:  77, revenue:   676_698,
      levels: { "黑卡" => { n: 11, amt: 144_600 }, "金卡" => { n: 11, amt: 142_827 },
                "銀卡" => { n: 13, amt: 166_843 }, "白卡" => { n: 18, amt: 166_280 }, "一般會員" => { n: 10, amt:  48_668 } } },
    { date: Date.new(2026,  5,  8), label: "5/8",  year: 2026, note: "蝦紅素、維DK鈣、薑黃",
      orders:  70, revenue:   633_562,
      levels: { "黑卡" => { n: 17, amt: 215_535 }, "金卡" => { n: 21, amt: 138_770 },
                "銀卡" => { n: 11, amt:  82_124 }, "白卡" => { n: 11, amt: 118_123 }, "一般會員" => { n:  7, amt:  47_680 } } },
    { date: Date.new(2026,  5, 22), label: "5/22", year: 2026, note: "穀胱甘肽、清纖粉、益生菌",
      orders: 165, revenue: 2_263_491,
      levels: { "黑卡" => { n: 19, amt: 810_218 }, "金卡" => { n: 15, amt: 325_408 },
                "銀卡" => { n: 15, amt: 298_669 }, "白卡" => { n: 17, amt: 351_622 }, "一般會員" => { n: 12, amt: 194_594 } } },
  ].freeze

  ALL_EVENTS = (EVENTS_2024 + EVENTS_2025 + EVENTS_2026).freeze

  WINDOW_DAYS = 1

  def index
    today = Date.today
    past_events = ALL_EVENTS.select { |e| e[:date] <= today }
    return (@events_data = []) if past_events.empty?

    @events_data = past_events.map do |event|
      range = event[:date].beginning_of_day..(event[:date] + WINDOW_DAYS).end_of_day
      db_emails = ShoplineOrder
        .where(order_date: range)
        .where.not(email: [nil, ""])
        .distinct.pluck(:email)
      event.merge(db_emails: db_emails)
    end

    # 場次選擇：?event=YYYY-MM-DD，預設最新
    selected_date = params[:event].presence && Date.parse(params[:event]) rescue nil
    @selected = (selected_date && @events_data.find { |e| e[:date] == selected_date }) || @events_data.last
    selected_idx = @events_data.index(@selected)

    # 連場回流率（只顯示 selected 及以前）
    events_up_to = @events_data[0..selected_idx]
    @return_rates = []
    events_up_to.each_cons(2) do |prev, curr|
      next if prev[:db_emails].empty? || curr[:db_emails].empty?
      overlap = (prev[:db_emails] & curr[:db_emails]).size
      @return_rates << {
        from: "#{prev[:year]}/#{prev[:label]}", to: "#{curr[:year]}/#{curr[:label]}",
        count: overlap, from_total: prev[:db_emails].size,
        rate: pct(overlap, prev[:db_emails].size)
      }
    end

    # DB 有資料的場次（selected 及以前）
    db_events = events_up_to.select { |e| e[:db_emails].any? }

    if db_events.size >= 2
      lookback      = db_events[-[4, db_events.size].min..-2]
      prev_emails   = lookback.flat_map { |e| e[:db_emails] }.uniq
      missing_emails = prev_emails - db_events.last[:db_emails]

      customers_map = ShoplineCustomer.where(email: missing_emails).index_by(&:email)

      @missing_customers = missing_emails.filter_map do |email|
        c = customers_map[email]
        next unless c
        appeared_in = lookback.select { |e| e[:db_emails].include?(email) }.map { |e| "#{e[:year]}/#{e[:label]}" }
        { customer: c, appeared_in: appeared_in, appeared_count: appeared_in.size }
      end.sort_by { |r|
        [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0),
         -r[:appeared_count],
         -r[:customer].total_amount.to_f]
      }
    else
      @missing_customers = []
    end

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

    @level_totals = ALL_LEVELS.index_with { |level| ShoplineCustomer.where(membership_level: level).count }

    build_insights
  end

  private

  def build_loyal_customers(emails, recent_events)
    return [] if emails.empty?

    ShoplineCustomer
      .where(email: emails)
      .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
      .map do |c|
        attended = recent_events.select { |e| e[:db_emails].include?(c.email) }.map { |e| "#{e[:year]}/#{e[:label]}" }
        { customer: c, attended_labels: attended }
      end
      .sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:customer].total_amount.to_f] }
  end

  def build_insights
    @insights = []
    return if @events_data.size < 2

    latest = @selected
    prev   = @events_data[@events_data.index(@selected) - 1]
    return unless prev

    if latest[:revenue] > 0 && prev[:revenue] > 0
      if latest[:revenue] > prev[:revenue]
        chg = ((latest[:revenue].to_f / prev[:revenue] - 1) * 100).round(0)
        @insights << { type: :success, text: "#{latest[:year]}/#{latest[:label]} 場次營業額較 #{prev[:year]}/#{prev[:label]} 成長 #{chg}%（NT$#{ActiveSupport::NumberHelper.number_to_delimited(latest[:revenue])}）。" }
      else
        chg = ((1 - latest[:revenue].to_f / prev[:revenue]) * 100).round(0)
        @insights << { type: :warning, text: "#{latest[:year]}/#{latest[:label]} 場次營業額較 #{prev[:year]}/#{prev[:label]} 下滑 #{chg}%（NT$#{ActiveSupport::NumberHelper.number_to_delimited(latest[:revenue])}）。" }
      end
    end

    top_level, top_data = latest[:levels].max_by { |_, v| v[:n] }
    @insights << { type: :info, text: "#{latest[:year]}/#{latest[:label]} 場次 #{top_level} 出席人數最多，共 #{top_data[:n]} 人。" }

    if @return_rates.any?
      rr = @return_rates.last
      if rr[:rate] >= 30
        @insights << { type: :success, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），黏著度良好。" }
      else
        @insights << { type: :warning, text: "#{rr[:from]} → #{rr[:to]} 連場回流率 #{rr[:rate]}%（#{rr[:count]}/#{rr[:from_total]} 人），建議直播前 2 天主動通知。" }
      end
    end

    if @missing_customers.any?
      black_n = @missing_customers.count { |r| r[:customer].membership_level == "黑卡" }
      suffix  = black_n > 0 ? "，其中 #{black_n} 位黑卡請優先聯繫" : ""
      @insights << { type: :danger, text: "#{@missing_customers.size} 位近期曾出席的客人 #{latest[:year]}/#{latest[:label]} 未出現#{suffix}。" }
    end

    @insights << { type: :success, text: "#{@loyal_3_customers.size} 位客人最近三場全勤，是核心忠實客，適合邀請為品牌大使。" } if @loyal_3_customers.size > 0
    @insights << { type: :info,    text: "#{@loyal_2_customers.size} 位客人近三場出席兩場，下場直播前建議主動通知。" } if @loyal_2_customers.size > 0
  end

  def pct(num, den)
    return 0.0 if den.zero?
    (num.to_f / den * 100).round(1)
  end
end
