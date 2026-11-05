# frozen_string_literal: true

module ReportCenter
  # 付款方式比例：銀行轉帳 7/17 改名要合併、中租分期數另外列；區間跨月時加每月佔比
  class Payments < Base
    GROUPS = ["信用卡一次", "信用卡分期", "中租", "LINE Pay", "Apple Pay", "銀行轉帳", "其他"].freeze

    def parts
      blocks = [heading("付款方式", "佔比以營收計"), group_table]
      if zingala.any?
        blocks.push(heading("中租期數"), table(["期數", "張數", "營收", "佔中租"], zingala_rows))
      end
      blocks.push(heading("每月佔比", "佔當月營收"), monthly_table) if months.size > 1
      [[:text, summary], tables(*blocks)]
    end

    private

    def summary
      lines = ["💳 #{label} 付款方式", "共 #{@data.all.size} 張單，營收 #{money(sum(@data.all))}", ""]
      groups.sort_by { |_, orders| -sum(orders) }.each do |name, orders|
        lines << "#{name} #{pct(sum(orders), sum(@data.all))}（#{orders.size} 張，#{money(sum(orders))}）"
      end
      installment = %w[信用卡分期 中租].sum { |g| sum(groups.fetch(g, [])) }
      lines << "" << "分期合計 #{pct(installment, sum(@data.all))}"
      lines.join("\n")
    end

    def group_of(payment)
      case payment.to_s
      when "信用卡付款" then "信用卡一次"
      when "信用卡分期付款" then "信用卡分期"
      when /\A中租/ then "中租"
      when /\ALINE Pay/i then "LINE Pay"
      when /\AApple Pay/i then "Apple Pay"
      when /\A銀行轉帳/ then "銀行轉帳"
      else "其他"
      end
    end

    def groups = @groups ||= @data.all.group_by { |o| group_of(o.payment) }

    def group_table
      rows = GROUPS.filter_map do |name|
        orders = groups[name]
        [name, orders.size, money(sum(orders)), pct(sum(orders), sum(@data.all)), money(sum(orders) / orders.size)] if orders
      end
      table(["付款方式", "張數", "營收", "佔營收", "客單價"], rows)
    end

    def zingala = groups.fetch("中租", [])

    def zingala_rows
      zingala.group_by { |o| o.payment[/\((\d+)期\)/, 1].to_i }.sort.map do |period, orders|
        ["#{period} 期", orders.size, money(sum(orders)), pct(sum(orders), sum(zingala))]
      end
    end

    def months = @months ||= @data.all.group_by { |o| o.date.beginning_of_month }.sort.to_h

    def monthly_table
      header = ["月份", *GROUPS.select { |g| groups.key?(g) }, "營收"]
      rows = months.map do |month, orders|
        by_group = orders.group_by { |o| group_of(o.payment) }
        ["#{month.year}/#{month.month}", *header[1..-2].map { |g| pct(sum(by_group.fetch(g, [])), sum(orders)) }, money(sum(orders))]
      end
      table(header, rows)
    end
  end
end
