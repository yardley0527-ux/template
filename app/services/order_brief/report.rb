# frozen_string_literal: true

module OrderBrief
  # 每日訂單簡報（使用者每天看的格式），LINE 純文字版。
  # 口徑跟使用者 10/19 定案的 order_brief.py 一樣：
  # - 只算已付款；整單金額取該張單 total_amount 的最大值（只記在其中一行）
  # - 卡別用客人「目前」的卡別（shopline_customers），不是下單當時的
  # - 新客＝當天以前（2024/1 起全部歷史）沒有已付款訂單，同 IG 的其他 email 也算同一人
  # - 瓶數＝品名數字 × quantity，「送M」另計；薑黃等「X N」＋「X N送M」成對重複行只留「送」那行
  # - 「以前買過 N 次」只算當天以前
  # LINE 沒有表格，表格改成一人一行；「90 天內回來」那張表跟上面各段重複，LINE 版不放。
  class Report
    FOCUS = %w[PDRN 全能].freeze # 有詳細段落的主力產品，換檔期改這裡
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

    # LINE 一則訊息上限 5,000 字，分段回傳讓呼叫端自己組
    def sections
      return [] if empty?

      ([overview] + FOCUS.map { |s| focus_section(s) } + [others_section, long_gap_section]).compact
    end

    def rows
      @rows ||= build_rows
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

    # ---- 文字 ----

    def overview
      new_rows, old_rows = rows.partition(&:new_customer?)
      total = rows.sum(&:amount)
      new_amount = new_rows.sum(&:amount)
      share = total.positive? ? (new_amount / total * 100).round : 0

      lines = ["📦 #{md(day)} 訂單簡報", "",
               "共 #{rows.size} 人下單、#{order_count(rows)} 張單，營收 #{money(total)}",
               "新客 #{new_rows.size} 人、#{order_count(new_rows)} 張單，#{money(new_amount)}（占 #{share}%）",
               "舊客 #{old_rows.size} 人、#{order_count(old_rows)} 張單，#{money(total - new_amount)}",
               "", "【依卡別】"]
      LEVELS.each do |level|
        rs = rows.select { |r| level_full(r.email) == level }
        extra = level == "一般會員" ? "（含新客 #{rs.count(&:new_customer?)} 人）" : ""
        lines << "#{level} #{rs.size} 人#{extra}#{rs.any? ? "，#{money(rs.sum(&:amount))}" : ''}"
      end

      lines += ["", "【依產品】"]
      product_stats.sort_by { |_, p| -p[:people].size }.each do |series, p|
        line = "#{series} #{p[:people].size} 人，付費 #{p[:paid]} 瓶"
        line += "，另送 #{p[:gift]} 瓶" if p[:gift].positive?
        line += p[:pre] == p[:paid] ? "（全部是預購）" : "（預購 #{p[:pre]} 瓶）" if p[:pre].positive?
        lines << line
      end
      lines.join("\n")
    end

    def product_stats
      stats = Hash.new { |h, k| h[k] = { people: Set.new, paid: 0, gift: 0, pre: 0 } }
      rows.each do |r|
        r.items.each do |name, k|
          series, n, gift = parse(name)
          p = stats[series]
          p[:people] << r.email
          p[:paid] += n * k
          p[:gift] += gift * k
          p[:pre] += n * k if name.start_with?("預購-")
        end
      end
      stats
    end

    def focus_section(series)
      buyers = rows.select { |r| row_series(r).include?(series) }
      return nil if buyers.empty? # 當天沒人買就整段不放

      repeat = buyers.select { |r| r.history.any? { |o| series_of(o).include?(series) } }
      first = buyers.select { |r| !r.new_customer? && !repeat.include?(r) }
      fresh = buyers.select(&:new_customer?)

      lines = ["【#{series}】#{buyers.size} 人：回購 #{repeat.size}、舊客第一次買 #{first.size}、新客 #{fresh.size}"]
      if repeat.any?
        lines += ["", "🔁 回購（依多久沒回來排序）"]
        repeat.map { |r| repeat_line(r, series) }.sort_by { |gap, _| -gap }.each { |_, l| lines << l }
      end
      if first.any?
        lines += ["", "🆕 舊客第一次買"]
        first.sort_by { |r| -gap(r.last_order.date) }.each do |r|
          lo = r.last_order
          lines << "・#{who(r)}：#{today_items(r)}，#{money(r.amount)}｜上次消費 #{md(lo.date)}，隔 #{gap(lo.date)} 天｜上次買#{disp(lo.items)}"
        end
      end
      lines += ["", "新客：" + fresh.map { |r| "#{name(r.email)}（#{today_items(r)}，#{money(r.amount)}）" }.join("、")] if fresh.any?
      lines.join("\n")
    end

    def repeat_line(row, series)
      past = row.history.select { |o| series_of(o).include?(series) }
      last = past.last
      g = gap(last.date)
      if series == "PDRN"
        now_b = row.orders.sum { |o| bottles(o, series) }
        last_b = bottles(last, series)
        note = "第 #{past.size + 1} 次買 PDRN"
        note += "，從 #{last_b} 瓶#{now_b > last_b ? '升' : '降'}到 #{now_b} 瓶" if now_b != last_b
        others = (row_series(row) - [series]).sort
        note += "，加購#{others.join('、')}" if others.any?
      else
        lo = row.last_order
        note = lo.equal?(last) ? "上次就是#{series}" : "最近一次 #{md(lo.date)} #{disp(lo.items)}"
        note += "（以前買過 #{past.size} 次#{series}）" if past.size > 1
      end
      last_items = last.items.select { |n, _| parse(n).first == series }
      [g, "・#{who(row)}：#{today_items(row)}，#{money(row.amount)}｜上次 #{md(last.date)} #{disp(last_items)}，隔 #{g} 天｜#{note}"]
    end

    def others_section
      old = rows.reject { |r| r.new_customer? || (row_series(r) & FOCUS).any? }
      fresh = rows.select { |r| r.new_customer? && (row_series(r) & FOCUS).empty? }
      return nil if old.empty? && fresh.empty?

      lines = ["【其他舊客】#{old.size} 人（沒買#{FOCUS.join('和')}）"]
      old.sort_by { |r| -gap(r.last_order.date) }.each do |r|
        lo = r.last_order
        same = r.history.select { |o| (series_of(o) & row_series(r)).any? }
        extra = same.any? ? "，上次買同品項 #{md(same.last.date)}" : "，第一次買這個品項"
        low = r.amount < 1000 ? "（實付很低，大概是購物金折抵）" : ""
        lines << "・#{who(r)}：#{today_items(r)}，#{money(r.amount)}#{low}，#{gap(lo.date)} 天沒來（上次 #{md(lo.date)} #{disp(lo.items)}）#{extra}"
      end
      lines += ["", "其他新客：" + fresh.map { |r| "#{name(r.email)}（#{today_items(r)}，#{money(r.amount)}）" }.join("、")] if fresh.any?
      lines.join("\n")
    end

    # 距離任何品項上一單 ≥ 90 天
    def long_gap_section
      back = rows.reject(&:new_customer?).select { |r| gap(r.last_order.date) >= LONG_GAP }
      return nil if back.empty?

      lines = ["【很久沒回來買的（≥#{LONG_GAP} 天）】#{back.size} 人"]
      back.sort_by { |r| -gap(r.last_order.date) }.each do |r|
        lo = r.last_order
        lines << "・#{who(r)}：隔 #{gap(lo.date)} 天（上次 #{md(lo.date)} #{disp(lo.items)}，以前買過 #{r.history.size} 次）"
      end
      lines.join("\n")
    end

    def level_full(email) = @customers.dig(email, :level).presence || "一般會員"
    def level(email) = SHORT_LEVEL.fetch(level_full(email), "一般")
    def name(email) = (@customers.dig(email, :name).presence || email.split("@").first).strip
    def who(row) = "#{name(row.email)}（#{level(row.email)}）"
    def order_count(rs) = rs.sum { |r| r.orders.size }
    def gap(date) = (day - date).to_i
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
    def md(date) = date.year == day.year ? "#{date.month}/#{date.day}" : "#{date.year}/#{date.month}/#{date.day}"

    def today_items(row)
      disp(row.items) + (row.orders.size > 1 ? "（#{row.orders.size} 張單）" : "")
    end

    def disp(items)
      items.each_with_object(Hash.new(0)) { |(n, k), h| h[n] += k }
           .map { |n, k| n.delete_prefix("預購-") + (k > 1 ? "×#{k}" : "") }.join("、")
    end
  end
end
