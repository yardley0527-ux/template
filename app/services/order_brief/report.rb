# frozen_string_literal: true

module OrderBrief
  # 每日訂單簡報（使用者每天看的格式）的資料；LINE Flex 總覽（FlexMessage）、
  # 客人明細卡（DetailCards）、AI 重點（Highlights）共用。口徑跟使用者 10/19 定案的 order_brief.py 一樣：
  # - 只算已付款；整單金額取該張單 total_amount 的最大值（只記在其中一行）
  # - 卡別用客人「目前」的卡別（shopline_customers），不是下單當時的
  # - 新客＝當天以前（2024/1 起全部歷史）沒有已付款訂單，同 IG 的其他 email 也算同一人
  # - 瓶數＝品名數字 × quantity，「送M」另計；薑黃等「X N」＋「X N送M」成對重複行只留「送」那行
  # - 「以前買過 N 次」只算當天以前
  class Report
    # 有詳細表的主力產品＝當天有人買大組數（一人付費 ≥ BIG_SET 瓶）的產品，每天自動判斷。
    # 2026-11-10 起：原本寫死 PDRN／全能，PDRN 賣完後改成看當天實際賣出大組數的產品。
    BIG_SET = 5
    LONG_GAP = 90
    LEVELS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
    SHORT_LEVEL = { "黑卡" => "黑", "金卡" => "金", "銀卡" => "銀", "白卡" => "白" }.freeze
    IG_JUNK = ["", "無", "na", "no", "n/a", "none", "-", "沒有", "x", "."].freeze

    Order = Struct.new(:date, :number, :items, :amount, keyword_init: true) # items: [[品名, quantity], ...]
    Row = Struct.new(:email, :orders, :history, keyword_init: true) do
      def amount = orders.sum(&:amount)
      def items = orders.flat_map(&:items)
      def new_customer? = history.empty?
      def last_order = history.last
      def first_date = orders.map(&:date).min
    end

    attr_reader :day, :days

    # 「預購-全能12送1」→ ["全能", 12, 1]
    def self.parse(name)
      base = name.delete_prefix("預購-")
      m = base.match(/\A(.*?)(\d+)(?:送(\d+))?\z/)
      m ? [m[1], m[2].to_i, m[3].to_i] : [base, 0, 0]
    end

    # day：一天（Date）或連續幾天（Range，合併成一份）。
    # 合併時新舊客、「隔幾天」都以這個人在這段期間的第一張單為準，這段期間內的多張單算同一次。
    def initialize(day)
      range = day.is_a?(Range) ? day : day..day
      @days = range.first.to_date..range.last.to_date
      @day = @days.last
    end

    def multi_day? = days.first != days.last
    def label = multi_day? ? "#{days.first.month}/#{days.first.day}–#{day.month}/#{day.day}" : "#{day.month}/#{day.day}"

    def empty?
      rows.empty?
    end

    def rows
      @rows ||= build_rows
    end

    # ---- 總覽 ----

    def summary
      new_rows, old_rows = rows.partition(&:new_customer?)
      total = rows.sum(&:amount)
      new_amount = new_rows.sum(&:amount)
      { people: rows.size, orders: order_count(rows), revenue: total,
        new_people: new_rows.size, new_orders: order_count(new_rows), new_revenue: new_amount,
        new_share: total.positive? ? (new_amount / total * 100).round : 0,
        old_people: old_rows.size, old_orders: order_count(old_rows), old_revenue: total - new_amount }
    end

    def level_stats
      LEVELS.map do |level|
        rs = rows.select { |r| level_full(r.email) == level }
        { level: level, people: rs.size, amount: rs.sum(&:amount), new_people: rs.count(&:new_customer?) }
      end
    end

    # 依人數多到少；pre＝預購瓶數
    def product_stats
      stats = Hash.new { |h, k| h[k] = { series: k, emails: Set.new, paid: 0, gift: 0, pre: 0 } }
      rows.each do |r|
        r.items.each do |name, k|
          series, n, gift = parse(name)
          p = stats[series]
          p[:emails] << r.email
          p[:paid] += n * k
          p[:gift] += gift * k
          p[:pre] += n * k if name.start_with?("預購-")
        end
      end
      stats.values.map { |p| p.except(:emails).merge(people: p[:emails].size) }.sort_by { |p| -p[:people] }
    end

    # ---- 客人明細 ----

    # 有人買大組數的產品，依付費瓶數多到少
    def focus_series
      @focus_series ||= begin
        per = Hash.new(0)
        rows.each { |r| r.items.each { |n, k| s, b, = parse(n); per[[r.email, s]] += b * k } }
        big = per.select { |_, b| b >= BIG_SET }.keys.map(&:last).uniq
        paid = product_stats.to_h { |p| [p[:series], p[:paid]] }
        big.sort_by { |s| -paid.fetch(s, 0) }
      end
    end

    # 今天下單、以前買過 PDRN 的舊客：PDRN 帶進來的新客（第一張單就有 PDRN）vs 原本舊客，依「距上次買 PDRN」多到少
    def pdrn_followups
      @pdrn_followups ||= rows.reject(&:new_customer?).filter_map do |r|
        past = r.history.select { |o| pdrn?(series_of(o)) }
        next if past.empty?

        base_entry(r).merge(brought: r.history.first.equal?(past.first), last_date: past.last.date,
                            gap: gap(r, past.last.date), times: past.size, big: (row_series(r) & focus_series).to_a.sort)
      end.sort_by { |e| -e[:gap] }
    end

    # 新客首單買什麼，依金額多到少
    def new_first_orders
      @new_first_orders ||= rows.select(&:new_customer?).map { |r| base_entry(r).merge(series: row_series(r).to_a.sort) }
                                .sort_by { |e| -e[:amount] }
    end

    # { buyers:, repeat: [...], first: [...], fresh: [...] }，回購／第一次買依「隔幾天」多到少
    def focus(series)
      @focus ||= {}
      @focus[series] ||= begin
        buyers = rows.select { |r| row_series(r).include?(series) }
        repeat = buyers.select { |r| r.history.any? { |o| series_of(o).include?(series) } }
        first = buyers.select { |r| !r.new_customer? && !repeat.include?(r) }
        { buyers: buyers.size,
          repeat: repeat.map { |r| repeat_entry(r, series) }.sort_by { |e| -e[:gap] },
          first: first.map { |r| first_entry(r) }.sort_by { |e| -e[:gap] },
          fresh: buyers.select(&:new_customer?).map { |r| base_entry(r) } }
      end
    end

    # 沒買主力產品的舊客（新客都在 new_first_orders）
    def other_old
      rows.reject { |r| r.new_customer? || (row_series(r) & focus_series).any? }.map do |r|
        same = r.history.select { |o| (series_of(o) & row_series(r)).any? }
        first_entry(r).merge(same_item_date: same.last&.date, low_amount: r.amount < 1000)
      end.sort_by { |e| -e[:gap] }
    end

    # 舊客依「距離任何品項上一單」分成 ≥90 天、90 天內兩張表
    def long_gap
      returning.select { |e| e[:gap] >= LONG_GAP }
    end

    def back_within
      returning.select { |e| e[:gap] < LONG_GAP }
    end

    # 給 AI 寫重點用：每位當天買家的完整購買歷史（含 IG 分身），避免只看上一單就下結論
    def customer_histories(max_orders: 20)
      rows.map do |r|
        { "客人" => name(r.email), "卡別" => level_full(r.email), "新客" => r.new_customer?,
          "今天買" => today_items(r), "今天整單" => r.amount.round,
          "以前已付款訂單數" => r.history.size,
          "購買歷史（舊到新，最多最近 #{max_orders} 張）" => r.history.last(max_orders).map { |o| "#{o.date} #{disp(o.items)} $#{o.amount.round}" } }
      end
    end

    def md(date) = date.year == day.year ? "#{date.month}/#{date.day}" : "#{date.year}/#{date.month}/#{date.day}"

    def disp(items)
      items.each_with_object(Hash.new(0)) { |(n, k), h| h[n] += k }
           .map { |n, k| n.delete_prefix("預購-") + (k > 1 ? "×#{k}" : "") }.join("、")
    end

    private

    # ---- 資料 ----

    def build_rows
      emails = paid_orders.where("order_date::date BETWEEN ? AND ?", days.first, days.last).distinct.pluck(Arel.sql("lower(trim(email))")).compact
      return [] if emails.empty?

      load_customers(emails)
      orders = load_orders(emails.flat_map { |e| siblings(e) }.uniq)

      emails.map do |email|
        todays = orders.fetch(email, []).select { |o| days.cover?(o.date) }
        first_date = todays.map(&:date).min
        history = first_date ? siblings(email).flat_map { |e| orders.fetch(e, []) }.select { |o| o.date < first_date }.sort_by { |o| [o.date, o.number] } : []
        Row.new(email: email, orders: todays, history: history)
      end.reject { |r| r.orders.empty? }
    end

    def paid_orders
      ShoplineOrder.where(payment_status: "已付款")
    end

    # 當天買家＋同 IG 的分身 email；只撈這些人，不把整張訂單表搬進記憶體
    def load_customers(emails)
      @customers = {}
      @by_ig = Hash.new { |h, k| h[k] = [] }
      igs = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails).pluck(Arel.sql("lower(trim(instagram_account))"))
                            .reject { |ig| ig.nil? || IG_JUNK.include?(ig) }.uniq
      scope = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails)
      scope = scope.or(ShoplineCustomer.where("lower(trim(instagram_account)) IN (?)", igs)) if igs.any?
      scope.pluck(Arel.sql("lower(trim(email))"), :full_name, :membership_level, Arel.sql("lower(trim(instagram_account))"))
           .each do |em, full_name, level, ig|
        ig = nil if ig.nil? || IG_JUNK.include?(ig)
        @customers[em] = { name: full_name, level: level, ig: ig }
        @by_ig[ig] << em if ig
      end
    end

    def siblings(email)
      ig = @customers.dig(email, :ig)
      ig ? ([email] + @by_ig[ig]).uniq : [email]
    end

    # 整單金額 total_amount 偶爾整張單都是空的，那就用各行 checkout_amount 加總（同 /daily_dashboard）
    def load_orders(emails)
      by_email = Hash.new { |h, k| h[k] = {} }
      checkout = Hash.new(0.0)
      paid_orders.where("lower(trim(email)) IN (?)", emails).where("order_date::date <= ?", day)
                 .pluck(Arel.sql("lower(trim(email))"), :order_number, Arel.sql("order_date::date"), :product_name, :quantity,
                        :total_amount, :checkout_amount)
                 .each do |em, number, date, name, qty, total, line_amount|
        order = (by_email[em][number] ||= Order.new(date: date.to_date, number: number, items: [], amount: 0))
        order.items << [name.to_s, (qty || 1).to_i]
        order.amount = [order.amount, total.to_f].max
        checkout[[em, number]] += line_amount.to_f
      end
      checkout.each do |(em, number), amount|
        order = by_email[em][number]
        order.amount = amount unless order.amount.positive?
      end
      by_email.transform_values { |orders| orders.values.each { |o| drop_paired_lines(o) } }
    end

    # 「薑黃3」＋「薑黃3送1」成對出現時只留「送」那行
    def drop_paired_lines(order)
      names = order.items.map(&:first)
      order.items.reject! do |name, _|
        series, n, gift = parse(name)
        gift.zero? && names.any? { |x| x.match?(/\A(預購-)?#{Regexp.escape(series)}#{n}送\d+\z/) }
      end
    end

    def parse(name) = self.class.parse(name)

    def pdrn?(series_set) = series_set.any? { |s| s.upcase.include?("PDRN") }
    def series_of(order) = order.items.map { |n, _| parse(n).first }.to_set
    def row_series(row) = row.orders.map { |o| series_of(o) }.reduce(Set.new, :|)
    def bottles(order, s) = order.items.sum { |n, k| parse(n)[0] == s ? parse(n)[1] * k : 0 }

    # ---- 明細列 ----

    def base_entry(row)
      { name: name(row.email), level: level(row.email), order_date: row.first_date, today: today_items(row), amount: row.amount }
    end

    def first_entry(row)
      lo = row.last_order
      base_entry(row).merge(last_date: lo.date, gap: gap(row, lo.date), last_items: disp(lo.items), times: row.history.size)
    end

    def repeat_entry(row, series)
      past = row.history.select { |o| series_of(o).include?(series) }
      last = past.last
      # 原本 PDRN 表的備註（第幾次買、瓶數升降、加購）＋全能表的「最近一次消費」
      now_b = row.orders.sum { |o| bottles(o, series) }
      last_b = bottles(last, series)
      note = "第 #{past.size + 1} 次買 #{series}"
      note += "，從 #{last_b} 瓶#{now_b > last_b ? '升' : '降'}到 #{now_b} 瓶" if now_b != last_b
      others = (row_series(row) - [series]).sort
      note += "，加購#{others.join('、')}" if others.any?
      lo = row.last_order
      note += "；最近一次消費 #{md(lo.date)} #{disp(lo.items)}" unless lo.equal?(last)
      # away：距離任何品項的上一單（簡報產品表只列 away ≥ LONG_GAP 的人）
      base_entry(row).merge(last_date: last.date, gap: gap(row, last.date), away: gap(row, lo.date), note: note,
                            last_items: disp(last.items.select { |n, _| parse(n).first == series }))
    end

    def returning
      @returning ||= rows.reject(&:new_customer?).map do |r|
        bought = r.history.map { |o| series_of(o) }.reduce(Set.new, :|)
        first_entry(r).merge(repurchased: (row_series(r) & bought).to_a.sort, first_time: (row_series(r) - bought).to_a.sort)
      end.sort_by { |e| -e[:gap] }
    end

    def level_full(email) = @customers.dig(email, :level).presence || "一般會員"
    def level(email) = SHORT_LEVEL.fetch(level_full(email), "一般")
    def name(email) = (@customers.dig(email, :name).presence || email.split("@").first).strip
    def order_count(rs) = rs.sum { |r| r.orders.size }
    def gap(row, date) = (row.first_date - date).to_i

    def today_items(row)
      notes = []
      notes << row.orders.map(&:date).uniq.sort.map { |d| "#{d.month}/#{d.day}" }.join("、") if multi_day?
      notes << "#{row.orders.size} 張單" if row.orders.size > 1
      disp(row.items) + (notes.any? ? "（#{notes.join('，')}）" : "")
    end
  end
end
