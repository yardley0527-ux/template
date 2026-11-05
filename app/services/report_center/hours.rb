# frozen_string_literal: true

module ReportCenter
  # 業績時段分佈：哪個時段賣最多、是新客還是舊客
  class Hours < Base
    BLOCKS = [[0, 8], [8, 12], [12, 16], [16, 20], [20, 24]].freeze
    HEADER = ["張數", "營收", "佔營收", "新客單", "新客營收", "舊客單", "舊客營收"].freeze

    def parts
      [[:text, summary],
       tables(heading("時段分佈"), table(["時段", *HEADER], block_rows),
              heading("每小時"), table(["小時", *HEADER], hour_rows))]
    end

    private

    def summary
      lines = ["🕒 #{label} 業績時段分佈", *overview]
      busiest = BLOCKS.max_by { |from, to| sum(in_hours(from...to)) }
      top = in_hours(busiest[0]...busiest[1])
      lines << "" << "最高時段 #{busiest[0]}–#{busiest[1]} 點：#{top.size} 張、#{money(sum(top))}（#{pct(sum(top), sum(@data.all))}）"
      lines << "新客集中 #{peak(@data.new_orders)}" if @data.new_orders.any?
      lines << "舊客集中 #{peak(@data.old_orders)}" if @data.old_orders.any?
      lines.join("\n")
    end

    def peak(orders)
      from, to = BLOCKS.max_by { |a, b| sum(orders.select { |o| o.hour && (a...b).cover?(o.hour) }) }
      part = orders.select { |o| o.hour && (from...to).cover?(o.hour) }
      "#{from}–#{to} 點（#{money(sum(part))}，佔該客群 #{pct(sum(part), sum(orders))}）"
    end

    def in_hours(hours) = @data.all.select { |o| o.hour && hours.cover?(o.hour) }

    def block_rows
      rows = BLOCKS.map { |from, to| row("#{from}–#{to} 點", in_hours(from...to)) }
      unknown = @data.all.reject(&:hour)
      rows << row("時間不明", unknown) if unknown.any?
      rows
    end

    def hour_rows = (0..23).map { |h| row("#{h} 點", in_hours(h..h)) }

    def row(name, orders)
      new_orders, old_orders = orders.partition(&:new_customer?)
      [name, orders.size, money(sum(orders)), pct(sum(orders), sum(@data.all)),
       new_orders.size, money(sum(new_orders)), old_orders.size, money(sum(old_orders))]
    end
  end
end
