# frozen_string_literal: true

require "open-uri"

# 從「苼莛國際＿年度行事曆」xlsx（連結共用）同步當年度的直播時程進行事曆。
# Excel 是唯一資料來源：新增/修改/刪除都以 Excel 為準——
# 同步時 upsert 每一場直播，Excel 上已移除的場次會一併刪除。
#
# 只同步「直播時間」列（有精確日期）。「新品」列只寫到月份，
# 實際到貨日都是另外確認的，所以到貨事件維持在系統內手動維護。
class AnnualCalendarSync
  SHEET_ID = "1XAv2T1pcYJ01ZLOklWIOUDaE3BnAWcbt"

  def self.call
    new.call
  end

  def call
    year = Date.current.year
    sheet = find_year_sheet(year)
    return { events: 0, error: "找不到 #{year % 100}總表 分頁" } if sheet.nil?

    desired = parse_livestreams(sheet, year)

    desired.each do |key, attrs|
      event = CalendarEvent.find_or_initialize_by(external_key: key)
      event.assign_attributes(attrs)
      event.save! if event.changed?
    end

    CalendarEvent
      .where("external_key LIKE ?", "annual:#{year}:live:%")
      .where.not(external_key: desired.keys)
      .destroy_all

    { events: desired.size, error: nil }
  rescue StandardError => e
    Rails.logger.error("[AnnualCalendarSync] #{e.class} #{e.message}")
    { events: 0, error: "#{e.class}: #{e.message}" }
  end

  private

  def find_year_sheet(year)
    url = "https://docs.google.com/spreadsheets/d/#{SHEET_ID}/export?format=xlsx"
    io = URI.parse(url).open(open_timeout: 15, read_timeout: 60)
    file = Tempfile.new(["annual_calendar", ".xlsx"], binmode: true)
    file.write(io.read)
    file.rewind
    xlsx = Roo::Excelx.new(file.path)
    tab = xlsx.sheets.find { |name| name.include?("#{year % 100}總表") }
    tab && xlsx.sheet(tab)
  end

  def parse_livestreams(sheet, year)
    live_row = (sheet.first_row..sheet.last_row)
               .find { |r| sheet.cell(r, 1).to_s.strip == "直播時間" }
    raise "找不到「直播時間」列" if live_row.nil?

    desired = {}
    (2..13).each do |col|
      parse_cell(sheet.cell(live_row, col).to_s, year).each do |entry|
        key = "annual:#{year}:live:#{entry[:date]}"
        desired[key] = {
          title:       entry[:products].any? ? "品牌之夜：#{entry[:products].join('、')}" : "品牌之夜（品項未定）",
          event_type:  "livestream",
          event_date:  entry[:date],
          time_info:   entry[:time_info].presence,
          description: "同步自「苼莛國際＿年度行事曆」#{year % 100}總表，時程異動請直接改 Excel"
        }
      end
    end
    desired
  end

  # 儲存格格式：日期行（例 "7/17（五）9-12"）後面接品項行，直到下一個日期行
  def parse_cell(text, year)
    entries = []
    text.split("\n").each do |line|
      line = line.strip
      next if line.blank?

      if (m = line.match(%r{\A(\d{1,2})/(\d{1,2})\b}))
        date = safe_date(year, m[1].to_i, m[2].to_i)
        next if date.nil?

        rest = line.delete_prefix(m[0]).gsub(/[（(][^（()）]{1,3}[)）]/, "").strip
        entries << { date: date, time_info: rest, products: [] }
      elsif entries.any?
        entries.last[:products] << line
      end
    end
    entries
  end

  def safe_date(year, month, day)
    Date.new(year, month, day)
  rescue ArgumentError
    nil
  end
end
