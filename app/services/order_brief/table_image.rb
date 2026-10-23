# frozen_string_literal: true

require "prawn"
require "prawn/table"

module OrderBrief
  # 把簡報的一段（標題、表格、說明文字）畫成一頁 PDF，頁高剛好包住內容；
  # 再由 ImageHost 交給 Cloudinary 轉成 PNG 發 LINE（LINE 卡片太窄排不下 7 欄的表）。
  # 字型用 vendor/fonts 的 Noto Sans TC；字型沒有的字（emoji、藏文符號）會被拿掉，不會變方框。
  class TableImage
    FONT_DIR = Rails.root.join("vendor/fonts")
    WIDTH = 900
    MARGIN = 24
    FONT_SIZE = 11
    HEADER_BG = "EFE7DD"
    BORDER = "C9BBAA"

    # blocks: [[:heading, "回購 PDRN（6 人）", "依「多久沒回來」排序"], [:table, header, rows, bold_cols], [:text, "..."]]
    def initialize(blocks)
      @blocks = blocks
    end

    def render
      height = MARGIN * 2 + measure
      pdf = document(height)
      # PDF 預設背景透明，轉 PNG 後會變黑底，先鋪白底
      pdf.canvas { pdf.fill_color "FFFFFF"; pdf.fill_rectangle [0, height], WIDTH, height; pdf.fill_color "000000" }
      draw(pdf)
      pdf.render
    end

    private

    def document(height)
      pdf = Prawn::Document.new(page_size: [WIDTH, height], margin: MARGIN)
      pdf.font_families.update("Noto" => { normal: FONT_DIR.join("NotoSansTC-Regular.ttf").to_s,
                                           bold: FONT_DIR.join("NotoSansTC-Bold.ttf").to_s })
      pdf.font("Noto", size: FONT_SIZE)
      pdf
    end

    # 先在一頁很高的草稿上量出每塊的高度
    def measure
      pdf = document(20_000)
      @blocks.sum { |block| block_height(pdf, block) }
    end

    def draw(pdf)
      @blocks.each do |kind, *args|
        case kind
        when :heading
          title, note = args
          pdf.formatted_text([{ text: clean(pdf, title), styles: [:bold], size: 14 },
                              ({ text: "  #{clean(pdf, note)}", size: 11, color: "8C8C8C" } if note.present?)].compact)
          pdf.move_down 6
        when :table
          build_table(pdf, *args).draw
          pdf.move_down 14
        when :text
          pdf.text clean(pdf, args.first), leading: 3
          pdf.move_down 10
        end
      end
    end

    def block_height(pdf, (kind, *args))
      inner = WIDTH - MARGIN * 2
      case kind
      when :heading
        title, note = args
        pdf.height_of_formatted([{ text: clean(pdf, "#{title}  #{note}"), styles: [:bold], size: 14 }], width: inner) + 6
      when :table then build_table(pdf, *args).height + 14
      when :text then pdf.height_of(clean(pdf, args.first), width: inner, leading: 3) + 10
      end
    end

    def build_table(pdf, header, rows, bold_cols = [])
      data = [header] + rows.map { |r| r.map { |c| clean(pdf, c.to_s) } }
      pdf.make_table(data, header: true, width: WIDTH - MARGIN * 2,
                           cell_style: { size: FONT_SIZE, padding: [5, 7], border_color: BORDER, border_width: 0.6 }) do |t|
        t.row(0).font_style = :bold
        t.row(0).background_color = HEADER_BG
        bold_cols.each { |i| t.column(i).rows(1..-1).font_style = :bold }
      end
    end

    # 字型裡沒有的字直接拿掉（例如 🐣、ིྀ），避免畫成方框
    def clean(pdf, str)
      str.to_s.each_char.select { |ch| ch.ord < 0x80 || pdf.font.glyph_present?(ch) }.join.squeeze(" ")
    end
  end
end
