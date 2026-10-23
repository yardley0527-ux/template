# frozen_string_literal: true

module OrderBrief
  # 每日訂單簡報（使用者每天看的格式）的資料；LINE Flex 總覽（FlexMessage）和
  # /order_briefs 明細頁共用。口徑跟使用者 10/19 定案的 order_brief.py 一樣：
  # - 只算已付款；整單金額取該張單 total_amount 的最大值（只記在其中一行）
  # - 卡別用客人「目前」的卡別（shopline_customers），不是下單當時的
  # - 新客＝當天以前（2024/1 起全部歷史）沒有已付款訂單，同 IG 的其他 email 也算同一人
  # - 瓶數＝品名數字 × quantity，「送M」另計；薑黃等「X N」＋「X N送M」成對重複行只留「送」那行
  # - 「以前買過 N 次」只算當天以前
  class Report
    FOCUS = %w[PDRN 全能].freeze # 有詳細表的主力產品，換檔期改這裡
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
    end

    attr_reader :day

    def initialize(day)
      @day = day.to_date
    end

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

    # 沒買主力產品的舊客／新客
    def other_old
      rows.reject { |r| r.new_customer? || (row_series(r) & FOCUS).any? }.map do |r|
        same = r.history.select { |o| (series_of(o) & row_series(r)).any? }
        first_entry(r).merge(same_item_date: same.last&.date, low_amount: r.amount < 1000)
      end.sort_by { |e| -e[:gap] }
    end

    def other_new
      rows.select { |r| r.new_customer? && (row_series(r) & FOCUS).empty? }.map { |r| base_entry(r) }
    end

    # 舊客依「距離任何品項上一單」分成 ≥90 天、90 天內兩張表
    def long_gap
      returning.select { |e| e[:gap] >= LONG_GAP }
    end

    def back_within
      returning.select { |e| e[:gap] < LONG_GAP }
    end

    def md(date) = date.year == day.year ? "#{date.month}/#{date.day}" : "#{date.year}/#{date.month}/#{date.day}"

    def disp(items)
      items.each_with_object(Hash.new(0)) { |(n, k), h| h[n] += k }
           .map { |n, k| n.delete_prefix("預購-") + (k > 1 ? "×#{k}" : "") }.join("、")
    end

    private

    # ---- 資料 ----

    def build_rows
      emails = paid_orders.where("order_date::date = ?", day).distinct.pluck(Arel.sql("lower(trim(email))")).compact
      return [] if emails.empty?

      load_customers(emails)
      orders = load_orders(emails.flat_map { |e| siblings(e) }.uniq)

      emails.map do |email|
        todays = orders.fetch(email, []).select { |o| o.date == day }
        history = siblings(email).flat_map { |e| orders.fetch(e, []) }.select { |o| o.date < day }.sort_by { |o| [o.date, o.number] }
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

    def load_orders(emails)
      by_email = Hash.new { |h, k| h[k] = {} }
      paid_orders.where("lower(trim(email)) IN (?)", emails).where("order_date::date <= ?", day)
                 .pluck(Arel.sql("lower(trim(email))"), :order_number, Arel.sql("order_date::date"), :product_name, :quantity, :total_amount)
                 .each do |em, number, date, name, qty, total|
        order = (by_email[em][number] ||= Order.new(date: date.to_date, number: number, items: [], amount: 0))
        order.items << [name.to_s, (qty || 1).to_i]
        order.amount = [order.amount, total.to_f].max
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

    # 「預購-全能12送1」→ ["全能", 12, 1]
    def parse(name)
      base = name.delete_prefix("預購-")
      m = base.match(/\A(.*?)(\d+)(?:送(\d+))?\z/)
      m ? [m[1], m[2].to_i, m[3].to_i] : [base, 0, 0]
    end

    def series_of(order) = order.items.map { |n, _| parse(n).first }.to_set
    def row_series(row) = row.orders.map { |o| series_of(o) }.reduce(Set.new, :|)
    def bottles(order, s) = order.items.sum { |n, k| parse(n)[0] == s ? parse(n)[1] * k : 0 }

    # ---- 明細列 ----

    def base_entry(row)
      { name: name(row.email), level: level(row.email), today: today_items(row), amount: row.amount }
    end

    def first_entry(row)
      lo = row.last_order
      base_entry(row).merge(last_date: lo.date, gap: gap(lo.date), last_items: disp(lo.items), times: row.history.size)
    end

    def repeat_entry(row, series)
      past = row.history.select { |o| series_of(o).include?(series) }
      last = past.last
      if series == "PDRN"
        now_b = row.orders.sum { |o| bottles(o, series) }
        last_b = bottles(last, series)
        note = "第 #{past.size + 1} 次買 PDRN"
        note += "，從 #{last_b} 瓶#{now_b > last_b ? '升' : '降'}到 #{now_b} 瓶" if now_b != last_b
        others = (row_series(row) - [series]).sort
        note += "，加購#{others.join('、')}" if others.any?
      else
        lo = row.last_order
        note = lo.equal?(last) ? "上次就是#{series}" : "#{md(lo.date)} #{disp(lo.items)}"
        note += "（以前買過 #{past.size} 次#{series}）" if past.size > 1
      end
      base_entry(row).merge(last_date: last.date, gap: gap(last.date), note: note,
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
    def gap(date) = (day - date).to_i

    def today_items(row)
      disp(row.items) + (row.orders.size > 1 ? "（#{row.orders.size} 張單）" : "")
    end
  end
end
