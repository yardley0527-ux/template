# frozen_string_literal: true

module OrderBrief
  # 客人明細的 LINE Flex 卡片：一張表一張卡（PDRN 回購、PDRN 舊客第一次買…），左右滑。
  # 每位客人：第一行「姓名・卡別｜隔幾天」，下面兩行小字寫今天買什麼、上次買什麼／備註。
  # 人多的表拆成好幾張（續）；卡片依大小裝進一則或多則 carousel 訊息。
  class DetailCards
    ROWS_PER_CARD = 15
    CARDS_PER_CAROUSEL = 12 # LINE 上限
    MAX_CAROUSEL_BYTES = 25_000 # 保守抓，避免超過 LINE Flex 訊息大小上限

    GRAY = "#8c8c8c"
    ACCENT = "#a0784f"

    def initialize(report)
      @report = report
    end

    # 回傳 Flex 訊息陣列（每則一個 carousel）
    def messages
      cards = tables.flat_map { |title, entries, kind| build_cards(title, entries, kind) }
      carousels = cards.each_with_object([[]]) do |card, acc|
        current = acc.last
        if current.any? && (current.size >= CARDS_PER_CAROUSEL || (current + [card]).to_json.bytesize > MAX_CAROUSEL_BYTES)
          acc << [card]
        else
          current << card
        end
      end.reject(&:empty?)

      carousels.each_with_index.map do |bubbles, i|
        suffix = carousels.size > 1 ? "（#{i + 1}/#{carousels.size}）" : ""
        { type: "flex", altText: "#{@report.day.month}/#{@report.day.day} 客人明細#{suffix}",
          contents: { type: "carousel", contents: bubbles } }
      end
    end

    private

    def tables
      list = Report::FOCUS.flat_map do |s|
        f = @report.focus(s)
        [["#{s} 回購", f[:repeat], :repeat], ["#{s} 舊客第一次買", f[:first], :first], ["#{s} 新客", f[:fresh], :new]]
      end
      list << ["其他舊客（沒買#{Report::FOCUS.join('和')}）", @report.other_old, :other]
      list << ["其他新客", @report.other_new, :new]
      list << ["很久沒回來（≥#{Report::LONG_GAP} 天）", @report.long_gap, :long]
      list.reject { |_, entries, _| entries.empty? }
    end

    def build_cards(title, entries, kind)
      slices = entries.each_slice(ROWS_PER_CARD).to_a
      slices.each_with_index.map do |slice, i|
        heading = "#{title} #{entries.size} 人#{slices.size > 1 ? "（#{i + 1}/#{slices.size}）" : ''}"
        rows = slice.flat_map.with_index { |e, j| (j.zero? ? [] : [{ type: "separator", margin: "md" }]) + [person(e, kind)] }
        { type: "bubble", size: "giga",
          header: { type: "box", layout: "vertical", paddingBottom: "6px",
                    contents: [text(heading, weight: "bold", size: "md", color: ACCENT)] },
          body: { type: "box", layout: "vertical", spacing: "sm", contents: rows } }
      end
    end

    def person(e, kind)
      top = [text("#{e[:name]}・#{e[:level]}", weight: "bold", size: "sm", flex: 5, wrap: true)]
      top << text("#{e[:gap]} 天", weight: "bold", size: "sm", flex: 2, align: "end") if e[:gap]
      lines = [{ type: "box", layout: "horizontal", contents: top },
               text("今天 #{e[:today]}｜#{money(e[:amount])}", size: "xs", wrap: true)]
      note = note_for(e, kind)
      lines << text(note, size: "xs", color: GRAY, wrap: true) if note.present?
      { type: "box", layout: "vertical", spacing: "xs", margin: "md", contents: lines }
    end

    def note_for(e, kind)
      case kind
      when :repeat then "上次 #{md(e[:last_date])}（#{e[:last_items]}）｜#{e[:note]}"
      when :first then "上次消費 #{md(e[:last_date])}：#{e[:last_items]}"
      when :other
        same = e[:same_item_date] ? "上次買同品項 #{md(e[:same_item_date])}" : "第一次買這個品項"
        low = e[:low_amount] ? "｜實付很低，大概是購物金折抵" : ""
        "上次 #{md(e[:last_date])} #{e[:last_items]}｜#{same}#{low}"
      when :long then "上次 #{md(e[:last_date])} #{e[:last_items]}｜以前買過 #{e[:times]} 次"
      end
    end

    def text(str, **opts) = { type: "text", text: str.to_s.presence || " " }.merge(opts.compact)
    def md(date) = @report.md(date)
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
