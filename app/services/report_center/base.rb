# frozen_string_literal: true

module ReportCenter
  # 回傳跟 OrderBrief::Sections#parts 一樣的格式，/order_briefs 用同一段畫面顯示：
  # [:text, 可複製文字] 或 [:image, 名稱, 標題, blocks]
  class Base
    def initialize(data)
      @data = data
    end

    private

    def label
      r = @data.range
      text = r.first == r.last ? md(r.first) : "#{md(r.first)}–#{md(r.last)}"
      @data.product ? "#{text}（含「#{@data.product}」的訂單，金額是整單）" : text
    end

    def tables(*blocks) = [:image, self.class.name, nil, blocks]
    def heading(title, sub = nil) = [:heading, title, sub]
    def table(header, rows) = [:table, header, rows, []]

    def sum(orders) = orders.sum(&:amount)
    def pct(part, whole) = whole.positive? ? "#{(part.to_f / whole * 100).round(1)}%" : "-"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
    def md(date) = "#{date.month}/#{date.day}"

    def overview(orders = @data.all)
      new_orders = orders.select(&:new_customer?)
      old_orders = orders.reject(&:new_customer?)
      ["共 #{@data.people(orders)} 人、#{orders.size} 張單，營收 #{money(sum(orders))}",
       "新客 #{@data.people(new_orders)} 人、#{new_orders.size} 張單，#{money(sum(new_orders))}（#{pct(sum(new_orders), sum(orders))}）",
       "舊客 #{@data.people(old_orders)} 人、#{old_orders.size} 張單，#{money(sum(old_orders))}（#{pct(sum(old_orders), sum(orders))}）"]
    end
  end
end
