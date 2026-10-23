# frozen_string_literal: true

module OrderBrief
  # 訂單簡報的 LINE Flex 卡片：營收、新舊客、卡別、產品排成小表格，
  # 客人明細太長不放，底部按鈕連到 /order_briefs 明細頁。
  class FlexMessage
    DETAIL_URL = "https://st-crm-v2.onrender.com/order_briefs"
    MAX_PRODUCTS = 12 # 產品太多卡片會很長，其餘合併成一列
    WEEKDAYS = %w[日 一 二 三 四 五 六].freeze

    GRAY = "#8c8c8c"
    ACCENT = "#a0784f"

    def initialize(report)
      @report = report
    end

    def detail_url
      "#{DETAIL_URL}?date=#{@report.day.iso8601}"
    end

    def alt_text
      s = @report.summary
      "📦 #{day_label} 訂單簡報：#{s[:people]} 人、#{s[:orders]} 張單，營收 #{money(s[:revenue])}"
    end

    def to_h
      { type: "flex", altText: alt_text, contents: bubble }
    end

    private

    def bubble
      { type: "bubble", size: "giga",
        header: box([text("📦 #{day_label} 訂單簡報", weight: "bold", size: "lg")], paddingBottom: "8px"),
        body: box(body_contents, spacing: "md"),
        footer: box([{ type: "button", style: "primary", color: ACCENT, height: "sm",
                       action: { type: "uri", label: "看客人明細", uri: detail_url } }]) }
    end

    def body_contents
      s = @report.summary
      [
        box([text(money(s[:revenue]), weight: "bold", size: "xxl"),
             text("#{s[:people]} 人・#{s[:orders]} 張單", size: "sm", color: GRAY)]),
        separator,
        section("新舊客", ["", "人數", "張單", "營收"], [
          ["新客", "#{s[:new_people]}", "#{s[:new_orders]}", "#{money(s[:new_revenue])}（#{s[:new_share]}%）"],
          ["舊客", "#{s[:old_people]}", "#{s[:old_orders]}", money(s[:old_revenue])]
        ]),
        separator,
        section("卡別", ["", "人數", "", "營收"], @report.level_stats.map do |l|
          label = l[:level] == "一般會員" && l[:new_people].positive? ? "一般（新客#{l[:new_people]}）" : l[:level]
          [label, l[:people].to_s, "", l[:people].positive? ? money(l[:amount]) : "—"]
        end),
        separator,
        section("產品", ["", "人數", "付費瓶", "另送"], product_rows),
        separator,
        section("主力產品", ["", "回購", "第一次", "新客"], Report::FOCUS.map do |series|
          f = @report.focus(series)
          [series, f[:repeat].size.to_s, f[:first].size.to_s, f[:fresh].size.to_s]
        end),
        text("很久沒回來（≥#{Report::LONG_GAP} 天）#{@report.long_gap.size} 人", size: "sm", color: GRAY)
      ]
    end

    def product_rows
      products = @report.product_stats
      shown = products.first(MAX_PRODUCTS).map do |p|
        paid = p[:pre] == p[:paid] && p[:pre].positive? ? "#{p[:paid]}（預購）" : p[:paid].to_s
        [p[:series], p[:people].to_s, paid, p[:gift].positive? ? p[:gift].to_s : "—"]
      end
      rest = products.drop(MAX_PRODUCTS)
      shown << ["其他 #{rest.size} 項", "", rest.sum { |p| p[:paid] }.to_s, ""] if rest.any?
      shown
    end

    # 標題＋表頭＋各列；第一欄靠左、其餘靠右
    def section(title, header, rows)
      box([text(title, weight: "bold", size: "sm", color: ACCENT), row(header, color: GRAY)] + rows.map { |r| row(r) }, spacing: "xs")
    end

    def row(cells, color: nil)
      flexes = [4, 2, 3, 5]
      contents = cells.each_with_index.map do |cell, i|
        text(cell.presence || " ", size: "sm", flex: flexes[i], align: i.zero? ? "start" : "end", color: color, wrap: true)
      end
      { type: "box", layout: "horizontal", contents: contents }
    end

    def box(contents, **opts) = { type: "box", layout: "vertical", contents: contents }.merge(opts)
    def separator = { type: "separator" }
    def text(str, **opts) = { type: "text", text: str.to_s }.merge(opts.compact)

    def day_label = "#{@report.day.month}/#{@report.day.day}（#{WEEKDAYS[@report.day.wday]}）"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
