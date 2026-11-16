# frozen_string_literal: true

module SalesDaily
  # 匯入前一天訂單後，推到有訂閱「sales_daily」的 LINE 群組（苼莛國際-銷售後台）：
  # 1. 前一天 SL 訂單數量（新舊客）
  # 2. 當月 1 號到前一天的累計業績（日目標 DAILY_TARGET 達標天數）
  # 3. 前一天的卡別、年齡層
  # 4. 前一天熱銷商品 Top 5（依數量）
  # 星期一一次匯入五六日時合併成一份（同 /daily_dashboard 星期一看三天）：數量段多列每天一行，
  # 卡別、年齡層、熱銷是這幾天合計。要報哪幾天看上次發到哪天（LineDigestDelivery.pending_days）。
  # 新舊客、整單金額的口徑跟訂單簡報（OrderBrief::Report）一樣：當天以前全部歷史＋IG 分身。
  # 所以數字會跟 /daily_dashboard 有小差異（後台用「查詢區間開始前有沒有買過」）。
  class LineDigest
    TOPIC = "sales_daily"
    DAILY_TARGET = 150_000 # 同 DailyDashboardController::DAILY_TARGET
    LEVELS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
    AGE_BANDS = ["20以下", "20-29", "30-39", "40-49", "50-59", "60+", "未知"].freeze
    TOP_PRODUCTS = 5
    WEEKDAYS = %w[日 一 二 三 四 五 六].freeze

    def self.after_import
      call(LineDigestDelivery.pending_days(TOPIC, through: Date.current - 1))
    rescue StandardError => e
      Rails.logger.warn("[sales_daily] LINE 推播失敗：#{e.class}: #{e.message}")
      0
    end

    # days：一天（Date）或連續幾天（Range）
    def self.call(days, force: false)
      new(days).call(force: force)
    end

    def initialize(days, line: LineBot::Client.new)
      days = days.is_a?(Range) ? days : days..days
      @days = days.first.to_date..days.last.to_date
      @day = @days.last
      @line = line
    end

    # 回傳發送的群組數；沒設定 LINE、沒有訂閱群組、最後一天沒訂單（還沒匯入）、已發過都回 0。
    # 已發紀錄記在最後一天
    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty? || !pushable?

      LineDigestDelivery.deliver_once(TOPIC, @day, force: force) { push(groups) }
    end

    def pushable? = !totals[@day].empty?

    # 直接發給這些群組，不看也不記「已發送」（/line_bot_groups 補發單一群組用）；回傳群組數
    def push(groups)
      texts = LineBot::Client.pack(sections)
      groups.each { |group| @line.push_texts(group.group_id, texts) }
      groups.size
    end

    def message
      sections.join("\n\n")
    end

    def sections
      [day_section, month_section, level_section, age_section, product_section]
    end

    # 這幾天都沒有訂單（還沒匯入）
    def empty? = @days.all? { |date| totals[date].empty? }

    def multi_day? = @days.count > 1

    # 多天時網頁上 sections 旁邊畫的直條圖（x 軸＝每一天）；一天時不畫。
    # key 對應 sections 的位置（0 訂單、2 卡別、3 年齡層、4 熱銷），stacked：疊起來是當天營收
    def charts
      return {} unless multi_day?

      labels = @days.map { |date| day_label(date) }
      by_day = ->(&block) { @days.map { |date| block.call(rows_on(date)).round } }
      # 舊客依卡別、新客一類（同文字）；未分級只有有人時才畫
      # slot＝固定顏色位置：同一個卡別／年齡層換日期也是同一個顏色
      level_series = (LEVELS + ["未分級"]).each_with_index.map do |level, i|
        { name: level, slot: i, data: by_day.call { |rs| amount(old_rows(rs).select { |r| level_of(r) == level }) } }
      end
      level_series.reject! { |s| s[:name] == "未分級" && s[:data].none?(&:positive?) }
      level_series << { name: "新客", slot: LEVELS.size + 1, data: by_day.call { |rs| amount(rs.select(&:new_customer?)) } }
      age_series = AGE_BANDS.each_with_index.filter_map do |band, i|
        data = by_day.call { |rs| amount(rs.select { |r| age_band(customer(r.email)[:birthdate]) == band }) }
        { name: band, slot: i, data: data } if data.any?(&:positive?)
      end

      { 0 => { title: "每天營收（舊客／新客）", unit: "$", stacked: true, labels: labels,
               series: [{ name: "舊客", data: by_day.call { |rs| amount(old_rows(rs)) } },
                        { name: "新客", data: by_day.call { |rs| amount(rs.select(&:new_customer?)) } }] },
        2 => { title: "每天各卡別營收", unit: "$", stacked: true, labels: labels, series: level_series },
        3 => { title: "每天各年齡層營收", unit: "$", stacked: true, labels: labels, series: age_series },
        4 => { title: "熱銷商品每天賣出個數", unit: "個", stacked: false, labels: labels, series: product_chart_series } }
    end

    private

    # 卡別、年齡層要每個人的資料，只為要報的這幾天（通常 1 天、星期一 3 天）建 Report
    def reports
      @reports ||= @days.to_h { |date| [date, OrderBrief::Report.new(date)] }
    end

    def rows_on(date) = reports[date].rows

    def rows
      @rows ||= @days.flat_map { |date| rows_on(date) }
    end

    # 每天的合計（當月累計）；不逐天建 Report，否則月底一次載入 30 份完整購買歷史會 OOM
    def totals
      @totals ||= OrderBrief::DailyTotals.new(@day.beginning_of_month.then { |m| [m, @days.first].min }..@day)
    end

    # 多天時不加總：每一天各一段（標題列一次，底下每天一塊）
    # mark：日期後面加的標記（例如當天達標 ✅）
    def per_day(title, mark: nil)
      return [title, *yield(rows_on(@day), @day)].join("\n") unless multi_day?

      blocks = @days.map { |date| ["#{day_label(date)}#{mark&.call(rows_on(date))}", *yield(rows_on(date), date)].join("\n") }
      ([title] + blocks).join("\n\n")
    end

    def old_rows(rs) = rs.reject(&:new_customer?)
    def level_of(row) = LEVELS.include?(customer(row.email)[:level]) ? customer(row.email)[:level] : "未分級"

    # ---- 1. 訂單數量 ----

    def day_section
      per_day("📊 #{range_label} SL 訂單", mark: ->(rs) { amount(rs) >= DAILY_TARGET ? " ✅" : " ❌" }) do |rs|
        new_rows, old = rs.partition(&:new_customer?)
        ["訂單 #{order_count(rs)} 單｜營收 #{money(amount(rs))}#{avg(rs)}",
         "舊客 #{stat(old)}#{avg(old)}",
         "新客 #{stat(new_rows)}#{avg(new_rows)}"]
      end
    end

    # ---- 2. 當月累計 ----

    # 只放累計；每天的明細看 /daily_dashboard（每天發都重複，手機上太長）
    def month_section
      days = (@day.beginning_of_month..@day).map { |date| totals[date] }
      total = days.sum(&:amount)
      met = days.count { |t| t.amount >= DAILY_TARGET }

      ["📅 #{@day.month} 月累計（#{md(@day.beginning_of_month)}–#{md(@day)}）",
       "#{money(total)}｜#{days.size} 天中 #{met} 天達標",
       "日均 #{money(total / days.size)}（日目標 #{money(DAILY_TARGET)}）",
       "舊客 #{money(days.sum(&:old_amount))}｜新客 #{money(days.sum(&:new_amount))}"].join("\n")
    end

    # ---- 3. 卡別、年齡層 ----

    # 舊客依目前卡別，新客另外一行（同 /daily_dashboard）
    def level_section
      per_day("👑 #{short_range} 購買卡別") do |rs|
        new_rows, old = rs.partition(&:new_customer?)
        lines = LEVELS.map do |level|
          ls = old.select { |r| customer(r.email)[:level] == level }
          "#{level} #{ls.any? ? "#{stat(ls)}#{avg(ls)}" : '0 人'}"
        end
        others = old.reject { |r| LEVELS.include?(customer(r.email)[:level]) }
        lines << "未分級 #{stat(others)}#{avg(others)}" if others.any?
        lines << "新客 #{stat(new_rows)}#{avg(new_rows)}"
      end
    end

    def age_section
      per_day("🎂 #{short_range} 年齡層") do |rs|
        groups = rs.group_by { |r| age_band(customer(r.email)[:birthdate]) }
        AGE_BANDS.filter_map { |band| (gs = groups[band]) && "#{band} #{stat(gs)}#{avg(gs)}" }
      end
    end

    # ---- 4. 熱銷商品 ----

    # 依數量排序；營業額用各行 checkout_amount，占比是占當天營收（同 /daily_dashboard「昨日主力商品」）
    def product_section
      per_day("🔥 #{short_range} 熱銷商品") do |rs, date|
        total = amount(rs)
        top_products(date).each_with_index.flat_map do |(name, qty, orders, revenue), i|
          share = total.positive? ? (revenue.to_f / total * 100).round(1) : 0
          ["#{i + 1}. #{name}", "  #{qty.to_i} 個／#{orders} 單｜#{money(revenue)}（#{share}%）"]
        end
      end
    end

    def top_products(date)
      (product_stats[date] || []).first(TOP_PRODUCTS)
    end

    # { date => [[品名, 數量, 單數, 營業額], ...] }，每天依數量、營業額多到少
    def product_stats
      @product_stats ||= ShoplineOrder.where(payment_status: "已付款")
                                      .where("order_date::date BETWEEN ? AND ?", @days.first, @days.last)
                                      .where.not(product_name: [nil, ""])
                                      .group(Arel.sql("order_date::date"), Arel.sql("trim(product_name)"))
                                      .pluck(Arel.sql("order_date::date"), Arel.sql("trim(product_name)"), Arel.sql("SUM(COALESCE(quantity, 1))"),
                                             Arel.sql("COUNT(DISTINCT order_number)"), Arel.sql("SUM(COALESCE(checkout_amount, 0))"))
                                      .group_by { |date, *| date.to_date }
                                      .transform_values { |list| list.map { |_, *r| r }.sort_by { |_, qty, _, rev| [-qty.to_i, -rev.to_f] } }
    end

    # 每天前 5 名的聯集，依這幾天賣出個數排序，最多 8 個（顏色只有 8 個）
    def product_chart_series
      qty = Hash.new { |h, k| h[k] = Hash.new(0) }
      product_stats.each { |date, list| list.each { |name, q, *| qty[name][date] = q.to_i } }
      names = @days.flat_map { |date| top_products(date).map(&:first) }.uniq
      names.sort_by { |n| -qty[n].values.sum }.first(8).map { |n| { name: n, data: @days.map { |d| qty[n][d] } } }
    end

    # ---- 共用 ----

    def customer(email)
      @customers ||= ShoplineCustomer.where("lower(trim(email)) IN (?)", rows.map(&:email).uniq)
                                     .pluck(Arel.sql("lower(trim(email))"), :membership_level, :birthdate)
                                     .each_with_object({}) { |(em, level, birthdate), h| h[em] ||= { level: level.presence, birthdate: birthdate } }
      @customers.fetch(email, {})
    end

    def age_band(birthdate)
      return "未知" unless birthdate

      case @day.year - birthdate.year
      when 0..19 then "20以下"
      when 20..29 then "20-29"
      when 30..39 then "30-39"
      when 40..49 then "40-49"
      when 50..59 then "50-59"
      else "60+"
      end
    end

    # 好幾天合併時同一個人可能出現在不同天，人數用 email 去重
    def stat(rs) = "#{rs.map(&:email).uniq.size}人/#{order_count(rs)}單 #{money(amount(rs))}"
    def avg(rs) = order_count(rs).positive? ? "（均 #{money(amount(rs) / order_count(rs))}）" : ""
    def amount(rs) = rs.sum(&:amount)
    def order_count(rs) = rs.sum { |r| r.orders.size }
    def day_label(date) = "#{md(date)}（#{WEEKDAYS[date.wday]}）"
    def range_label = @days.count > 1 ? "#{day_label(@days.first)}–#{day_label(@days.last)}" : day_label(@day)
    def short_range = @days.count > 1 ? "#{md(@days.first)}–#{md(@days.last)}" : md(@day)
    def md(date) = "#{date.month}/#{date.day}"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
