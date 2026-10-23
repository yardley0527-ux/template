# frozen_string_literal: true

module SalesDaily
  # 匯入前一天訂單後，推到有訂閱「sales_daily」的 LINE 群組（苼莛國際-銷售後台）：
  # 1. 前一天 SL 訂單數量（新舊客）
  # 2. 當月 1 號到前一天的累計業績（日目標 DAILY_TARGET 達標天數）
  # 3. 前一天的卡別、年齡層
  # 4. 前一天熱銷商品 Top 5（依數量）
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
      call(Date.current - 1)
    rescue StandardError => e
      Rails.logger.warn("[sales_daily] LINE 推播失敗：#{e.class}: #{e.message}")
      0
    end

    def self.call(day, force: false)
      new(day).call(force: force)
    end

    def initialize(day, line: LineBot::Client.new)
      @day = day.to_date
      @line = line
    end

    # 回傳發送的群組數；沒設定 LINE、沒有訂閱群組、當天沒訂單（還沒匯入）、已發過都回 0
    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty? || report(@day).empty?

      LineDigestDelivery.deliver_once(TOPIC, @day, force: force) do
        texts = LineBot::Client.pack(sections)
        groups.each { |group| @line.push_texts(group.group_id, texts) }
        groups.size
      end
    end

    def message
      sections.join("\n\n")
    end

    def sections
      [day_section, month_section, level_section, age_section, product_section]
    end

    private

    def report(date)
      @reports ||= {}
      @reports[date] ||= OrderBrief::Report.new(date)
    end

    def rows = report(@day).rows

    # ---- 1. 前一天訂單數量 ----

    def day_section
      new_rows, old_rows = rows.partition(&:new_customer?)
      ["📊 #{day_label(@day)} SL 訂單",
       "訂單 #{order_count(rows)} 單｜營收 #{money(amount(rows))}#{avg(rows)}",
       "舊客 #{stat(old_rows)}#{avg(old_rows)}",
       "新客 #{stat(new_rows)}#{avg(new_rows)}"].join("\n")
    end

    # ---- 2. 當月累計 ----

    # 只放累計；每天的明細看 /daily_dashboard（每天發都重複，手機上太長）
    def month_section
      days = (@day.beginning_of_month..@day).map { |date| report(date).rows }
      all = days.flatten
      new_rows, old_rows = all.partition(&:new_customer?)
      met = days.count { |rs| amount(rs) >= DAILY_TARGET }

      ["📅 #{@day.month} 月累計（#{md(@day.beginning_of_month)}–#{md(@day)}）",
       "#{money(amount(all))}｜#{days.size} 天中 #{met} 天達標",
       "日均 #{money(amount(all) / days.size)}（日目標 #{money(DAILY_TARGET)}）",
       "舊客 #{money(amount(old_rows))}｜新客 #{money(amount(new_rows))}"].join("\n")
    end

    # ---- 3. 卡別、年齡層 ----

    # 舊客依目前卡別，新客另外一行（同 /daily_dashboard）
    def level_section
      new_rows, old_rows = rows.partition(&:new_customer?)
      lines = ["👑 #{md(@day)} 購買卡別"]
      LEVELS.each do |level|
        rs = old_rows.select { |r| customer(r.email)[:level] == level }
        lines << "#{level} #{rs.any? ? "#{stat(rs)}#{avg(rs)}" : '0 人'}"
      end
      others = old_rows.reject { |r| LEVELS.include?(customer(r.email)[:level]) }
      lines << "未分級 #{stat(others)}#{avg(others)}" if others.any?
      lines << "新客 #{stat(new_rows)}#{avg(new_rows)}"
      lines.join("\n")
    end

    def age_section
      groups = rows.group_by { |r| age_band(customer(r.email)[:birthdate]) }
      lines = ["🎂 #{md(@day)} 年齡層"]
      AGE_BANDS.each do |band|
        rs = groups[band]
        lines << "#{band} #{stat(rs)}#{avg(rs)}" if rs
      end
      lines.join("\n")
    end

    # ---- 4. 熱銷商品 ----

    # 依數量排序；營業額用各行 checkout_amount，占比是占當天營收（同 /daily_dashboard「昨日主力商品」）
    def product_section
      products = ShoplineOrder.where(payment_status: "已付款").where("order_date::date = ?", @day)
                              .where.not(product_name: [nil, ""])
                              .group(Arel.sql("trim(product_name)"))
                              .order(Arel.sql("SUM(COALESCE(quantity, 1)) DESC, SUM(COALESCE(checkout_amount, 0)) DESC"))
                              .limit(TOP_PRODUCTS)
                              .pluck(Arel.sql("trim(product_name)"), Arel.sql("SUM(COALESCE(quantity, 1))"),
                                     Arel.sql("COUNT(DISTINCT order_number)"), Arel.sql("SUM(COALESCE(checkout_amount, 0))"))
      total = amount(rows)
      lines = ["🔥 #{md(@day)} 熱銷商品"]
      products.each_with_index do |(name, qty, orders, revenue), i|
        share = total.positive? ? (revenue.to_f / total * 100).round(1) : 0
        lines << "#{i + 1}. #{name}"
        lines << "  #{qty.to_i} 個／#{orders} 單｜#{money(revenue)}（#{share}%）"
      end
      lines.join("\n")
    end

    # ---- 共用 ----

    def customer(email)
      @customers ||= ShoplineCustomer.where("lower(trim(email)) IN (?)", rows.map(&:email))
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

    def stat(rs) = "#{rs.size}人/#{order_count(rs)}單 #{money(amount(rs))}"
    def avg(rs) = order_count(rs).positive? ? "（均 #{money(amount(rs) / order_count(rs))}）" : ""
    def amount(rs) = rs.sum(&:amount)
    def order_count(rs) = rs.sum { |r| r.orders.size }
    def day_label(date) = "#{md(date)}（#{WEEKDAYS[date.wday]}）"
    def md(date) = "#{date.month}/#{date.day}"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
