# frozen_string_literal: true

module ReportCenter
  # 產品銷售＋組合比例：每個產品誰買的、賣多少；每個組合（1/3/5/10…）的佔比
  # 營收是把整單實付按標價比例攤到各行；數量單位各產品不同（薑黃＝瓶、膠原＝盒），所以寫「數量」
  class Products < Base
    MIN_SIZE_ROWS = 2 # 只有一種組合的產品不用看比例

    def parts
      [[:text, summary],
       tables(heading("產品銷售", "數量＝品名數字 × quantity，不含贈品；營收按標價比例攤提"), product_table),
       tables(heading("組合比例", "同單加購＝同一張單還買了同產品的其他組合"), mix_table)]
    end

    private

    Stat = Struct.new(:series, :people, :new_people, :old_people, :paid, :gift, :pre, :revenue, keyword_init: true)

    def summary
      lines = ["📦 #{label} 產品銷售", *overview, ""]
      stats.first(8).each do |s|
        line = "#{s.series} #{s.people.size} 人，數量 #{s.paid}，#{money(s.revenue)}"
        line += "（新客 #{s.new_people.size} 人）" if s.new_people.any?
        lines << line
      end
      lines.join("\n")
    end

    def stats
      @stats ||= begin
        by_series = Hash.new { |h, k| h[k] = Stat.new(series: k, people: Set.new, new_people: Set.new, old_people: Set.new, paid: 0, gift: 0, pre: 0, revenue: 0.0) }
        @data.all.each do |order|
          person = @data.identity.person(order.email)
          order.lines.each do |line|
            s = by_series[line.series]
            s.people << person
            (order.new_customer? ? s.new_people : s.old_people) << person
            s.paid += line.bottles
            s.gift += line.gift_bottles
            s.pre += line.bottles if line.preorder?
            s.revenue += line.list_amount * order.share
          end
        end
        by_series.values.sort_by { |s| -s.revenue }
      end
    end

    def product_table
      rows = stats.map do |s|
        [s.series, s.people.size, s.new_people.size, s.old_people.size, s.paid, s.gift, s.pre, money(s.revenue), pct(s.revenue, sum(@data.all))]
      end
      table(%w[產品 買家 新客 舊客 付費數量 名目另送 預購數量 營收 佔營收], rows)
    end

    def mix_table
      rows = series_lines.flat_map do |series, entries|
        total_sets = entries.sum { |e| e[:sets] }
        total_bottles = entries.sum { |e| e[:sets] * e[:size] }
        entries.group_by { |e| e[:size] }.sort.map do |size, group|
          sets = group.sum { |e| e[:sets] }
          [series, "#{size}", sets, pct(sets, total_sets), sets * size, pct(sets * size, total_bottles), group.count { |e| e[:add_on] }]
        end
      end
      table(%w[產品 組合 組數 組數佔比 數量 數量佔比 同單加購], rows)
    end

    # 有指定產品就只看那個產品；沒指定看賣最多的幾個，且要有 2 種以上組合
    def series_lines
      lines = Hash.new { |h, k| h[k] = [] }
      @data.all.each do |order|
        order.lines.select { |l| l.size.positive? }.group_by(&:series).each do |series, group|
          next if @data.product && !@data.match?(series)

          sizes = group.map(&:size).uniq
          group.each { |l| lines[series] << { size: l.size, sets: l.quantity, add_on: sizes.size > 1 } }
        end
      end
      lines.select { |_, entries| entries.map { |e| e[:size] }.uniq.size >= MIN_SIZE_ROWS }
           .sort_by { |_, entries| -entries.sum { |e| e[:size] * e[:sets] } }.first(@data.product ? 20 : 6)
    end
  end
end
