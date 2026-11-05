# frozen_string_literal: true

module ReportCenter
  # 買了某產品、之後沒回來的名單（訊息名單前的檢視，只看不灌名單）。
  # - 新客：人生第一天下單（2024/1 起全部歷史＋IG 分身）落在區間內、當天買了該產品
  # - 全部買家：區間內最後一次買該產品的那天
  # - 同一天的多張單算同一次購買（金額加總）；之後「任何產品」有訂單就算回來了
  # - 黑名單（含 IG 分身）一律排除，並寫出排除了誰
  class Unrepurchased
    Entry = Struct.new(:name, :level, :ig, :line, :date, :days, :items, :amount, :note, keyword_init: true)

    attr_reader :product, :range

    def initialize(product:, range:, audience: "new", min_amount: 0, exclude_preorder: false, skip_days: 0, today: Date.current)
      @product = product.to_s.strip
      @audience = audience
      @min_amount = min_amount.to_f
      @exclude_preorder = exclude_preorder
      @skip_days = skip_days.to_i
      @today = today
      @range = range.first..[range.last, today - 1 - @skip_days].min
    end

    def parts
      [[:text, summary], [:image, "list", nil, [[:heading, "名單 #{entries.size} 人", "金額高到低；同一天的訂單合併"],
                                                [:table, %w[姓名 卡別 IG LINE 購買日 距今 買了什麼 金額 備註], rows, [7]]]]]
    end

    def entries = result[:entries]
    def buyers = result[:buyers]
    def returned = result[:returned]
    def excluded = result[:excluded]

    private

    def result = @result ||= build

    def summary
      lines = ["📋 #{product} #{@audience == 'new' ? '新客' : '買家'}沒回來名單",
               "購買日 #{md(range.first)}–#{md(range.last)}#{"（排除近 #{@skip_days} 天）" if @skip_days.positive?}#{'・排除預購' if @exclude_preorder}#{"・該次 #{money(@min_amount)} 以上" if @min_amount.positive?}",
               "", "買家 #{buyers} 人，之後有回來 #{returned} 人，沒回來 #{buyers - returned} 人",
               "符合金額門檻 #{entries.size} 人，合計 #{money(entries.sum(&:amount))}（有 LINE #{entries.count(&:line)} 人）",
               excluded.any? ? "已排除黑名單 #{excluded.size} 人（#{excluded.join('、')}）" : "已檢查黑名單，0 人命中"]
      lines.join("\n")
    end

    def build
      return { entries: [], buyers: 0, returned: 0, excluded: [] } if product.blank? || range.first > range.last

      emails = candidate_emails
      ident = Identity.new(emails)
      everyone = emails.flat_map { |e| ident.siblings(e) }.uniq
      days = Hash.new { |h, k| h[k] = Hash.new { |d, date| d[date] = [] } }
      Orders.assemble(Orders.paid.where("lower(trim(email)) IN (?)", everyone)).each { |o| days[ident.person(o.email)][o.date] << o }

      blacklist = MessageListBuilder.blacklisted_emails
      entries = []
      excluded = []
      buyers = returned = 0
      days.each_value do |by_day|
        anchor = anchor_day(by_day)
        next unless anchor

        buyers += 1
        if by_day.keys.max > anchor
          returned += 1
          next
        end
        orders = by_day[anchor]
        email = orders.first.email
        next if orders.sum(&:amount) < @min_amount

        if ident.siblings(email).any? { |e| blacklist.key?(e) }
          excluded << display_name(ident, email)
          next
        end
        entries << entry(ident, email, orders, by_day)
      end
      { entries: entries.sort_by { |e| -e.amount }, buyers: buyers, returned: returned, excluded: excluded.uniq }
    end

    def candidate_emails
      scope = Orders.paid.where("order_date::date BETWEEN ? AND ?", range.first, range.last)
                    .where("product_name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(product)}%")
      scope = scope.where.not("product_name LIKE ?", "預購-%") if @exclude_preorder
      scope.distinct.pluck(Arel.sql("lower(trim(email))")).compact_blank
    end

    def anchor_day(by_day)
      hit = by_day.select { |date, orders| range.cover?(date) && orders.any? { |o| o.lines.any? { |l| match?(l) } } }.keys
      return hit.max unless @audience == "new"

      first = by_day.keys.min
      first if hit.include?(first)
    end

    def match?(line)
      line.name.downcase.include?(product.downcase) && !(@exclude_preorder && line.preorder?)
    end

    def entry(ident, email, orders, by_day)
      c = ident.customer(email)
      db_orders = by_day.values.sum(&:size)
      Entry.new(name: display_name(ident, email), level: c[:level] || "一般會員", ig: c[:ig], line: c[:line_id],
                date: orders.first.date, days: (@today - orders.first.date).to_i, amount: orders.sum(&:amount),
                items: items(orders), note: ("可能舊客（Shopline 有 #{c[:order_count]} 單）" if c[:order_count].to_i > db_orders))
    end

    def display_name(ident, email) = ident.customer(email)[:name] || email.split("@").first

    def items(orders)
      orders.flat_map(&:lines).each_with_object(Hash.new(0)) { |l, h| h[l.name.delete_prefix("預購-")] += l.quantity }
            .map { |name, k| k > 1 ? "#{name}×#{k}" : name }.join("、")
    end

    def rows
      entries.map do |e|
        [e.name, e.level, e.ig ? "@#{e.ig}" : "", e.line ? "有" : "", md(e.date), "#{e.days} 天", e.items, money(e.amount), e.note]
      end
    end

    def md(date) = "#{date.month}/#{date.day}"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
