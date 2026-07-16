# frozen_string_literal: true

require "open-uri"

# 同步 DANDY 產品庫存試算表（Drive 上的 xlsx，需開啟「知道連結的人可檢視」）。
# 只解析兩個分頁，結果整份存進 dandy_inventory_snapshots.data（每天一列，
# 同一天重複同步會覆蓋）：
# - 「庫存_X月」：保健品庫存總表（永吉路／入庫存／出庫／員購&其他／億元／
#   即時庫存＋預定到貨日期）。分頁每月改名，用月份規則抓。
# - 「按摩棒、藥盒庫存」：品名列在即時庫存列上方（女神儀式金盒在更上層的
#   合併儲存格），即時庫存列之後第一列是當月 1 號的期初量，再來每列是當日異動。
class DandyInventorySync
  FILE_ID = "1x89aA8CeaQCYVUOY5Wg7pohPlKRTPJRQ"
  SUPPLEMENT_SHEET_PATTERN = /\A庫存_\d{1,2}月\z/
  ACCESSORY_SHEET = "按摩棒、藥盒庫存"

  SUPPLEMENT_COLUMNS = ["永吉路", "入庫存", "出庫(檢貨單)", "員購&其他", "永吉路(庫存)", "億元", "即時庫存"].freeze
  ARRIVAL_COLUMN = "預定到貨日期"

  LAST_RUN_CACHE_KEY = "dandy_inventory_sync/last_run_at"

  class << self
    # cache store 不可用時的程序內備援，避免每個 request 都觸發背景同步
    attr_accessor :memory_last_run_at
  end

  # file_path：測試／手動匯入時直接給本機 xlsx，跳過下載
  def self.call(file_path: nil)
    new(file_path: file_path).call
  end

  def initialize(file_path: nil)
    @file_path = file_path
  end

  def call
    run = SyncRun.create!(source: "dandy_inventory", started_at: Time.current)

    xlsx = @file_path ? Roo::Excelx.new(@file_path) : download_workbook
    supplements = parse_supplements(xlsx)
    accessories = parse_accessories(xlsx)
    latest = latest_entry_date(accessories)

    DandyInventorySnapshot
      .find_or_initialize_by(snapshot_date: Date.current)
      .update!(
        synced_at:         Time.current,
        latest_entry_date: latest,
        data:              { "supplements" => supplements, "accessories" => accessories }
      )

    run.update!(
      status:      "success",
      finished_at: Time.current,
      meta:        {
        supplement_sheet:   supplements["sheet_name"],
        supplement_rows:    supplements["rows"].size,
        accessory_products: accessories["products"].size,
        latest_entry_date:  latest&.to_s
      }
    )
    self.class.mark_run!
    { error: nil }
  rescue StandardError => e
    Rails.logger.error("[DandyInventorySync] #{e.class} #{e.message}")
    run&.update!(status: "failed", finished_at: Time.current,
                 error_messages: ["#{e.class}: #{e.message}"])
    { error: "#{e.class}: #{e.message}" }
  end

  def self.last_run_at
    [
      SyncRun.last_finished_at("dandy_inventory"),
      Rails.cache.read(LAST_RUN_CACHE_KEY),
      memory_last_run_at
    ].compact.max
  end

  def self.mark_run!(time = Time.current)
    self.memory_last_run_at = time
    Rails.cache.write(LAST_RUN_CACHE_KEY, time)
  end

  def self.stale?
    last = last_run_at
    last.nil? || last < 1.hour.ago
  end

  private

  def download_workbook
    url = "https://docs.google.com/spreadsheets/d/#{FILE_ID}/export?format=xlsx"
    io = URI.parse(url).open(open_timeout: 15, read_timeout: 60)
    file = Tempfile.new(["dandy_inventory", ".xlsx"], binmode: true)
    file.write(io.read)
    file.rewind
    Roo::Excelx.new(file.path)
  end

  def parse_supplements(xlsx)
    sheet_name = xlsx.sheets.find { |s| s.strip.match?(SUPPLEMENT_SHEET_PATTERN) }
    raise "找不到「庫存_X月」分頁（目前分頁：#{xlsx.sheets.join('、')}）" unless sheet_name

    sheet = xlsx.sheet(sheet_name)
    header_index = (sheet.first_row..sheet.last_row).find do |i|
      cells = sheet.row(i).map { |c| normalize(c) }
      cells.include?("永吉路") && cells.include?("即時庫存")
    end
    raise "「#{sheet_name}」找不到標題列（永吉路／即時庫存）" unless header_index

    header = sheet.row(header_index).map { |c| normalize(c) }
    col_of = SUPPLEMENT_COLUMNS.index_with { |label| header.index(label) }
    missing = col_of.select { |_, idx| idx.nil? }.keys
    raise "「#{sheet_name}」缺少欄位：#{missing.join('、')}" if missing.any?

    arrival_index = header.index(ARRIVAL_COLUMN)

    rows = []
    total = nil
    ((header_index + 1)..sheet.last_row).each do |i|
      raw = sheet.row(i)
      product = raw[0].to_s.strip
      next if product.blank?

      entry = {
        "name"    => product,
        "values"  => SUPPLEMENT_COLUMNS.map { |label| numeric(raw[col_of[label]]) },
        "arrival" => arrival_index ? raw[arrival_index].to_s.strip.presence : nil
      }
      product == "小計" ? total = entry : rows << entry
    end

    {
      "sheet_name" => sheet_name,
      "title"      => sheet.cell(sheet.first_row, 1).to_s.strip,
      "columns"    => SUPPLEMENT_COLUMNS,
      "rows"       => rows,
      "total"      => total
    }
  end

  def parse_accessories(xlsx)
    sheet_name = xlsx.sheets.find { |s| s.strip == ACCESSORY_SHEET }
    raise "找不到「#{ACCESSORY_SHEET}」分頁" unless sheet_name

    sheet = xlsx.sheet(sheet_name)
    realtime_index = (sheet.first_row..sheet.last_row).find do |i|
      sheet.cell(i, 1).to_s.strip == "即時庫存"
    end
    raise "「#{ACCESSORY_SHEET}」找不到「即時庫存」列" unless realtime_index

    header_rows = (sheet.first_row...realtime_index).map { |i| sheet.row(i) }
    columns = (2..sheet.last_column).map do |col|
      name = header_rows.filter_map { |r| r[col - 1].to_s.strip.presence }.last
      { col: col, name: name, realtime: numeric(sheet.cell(realtime_index, col)) }
    end

    daily = ((realtime_index + 1)..sheet.last_row).filter_map do |i|
      date = to_date(sheet.cell(i, 1))
      next unless date

      { "date" => date.iso8601, "values" => columns.map { |c| numeric(sheet.cell(i, c[:col])) } }
    end

    # 沒名字也沒任何數字的欄位（純排版空欄）整欄剔除
    keep = columns.each_index.select do |idx|
      columns[idx][:name].present? ||
        columns[idx][:realtime].present? ||
        daily.any? { |row| row["values"][idx].present? }
    end

    {
      "products" => keep.map { |idx| { "name" => columns[idx][:name] || "（未命名）", "realtime" => columns[idx][:realtime] } },
      "daily"    => daily.map { |row| { "date" => row["date"], "values" => row["values"].values_at(*keep) } }
    }
  end

  def latest_entry_date(accessories)
    dated = accessories["daily"].select { |row| row["values"].any?(&:present?) }
    dated.map { |row| Date.parse(row["date"]) }.max
  end

  def normalize(cell)
    cell.to_s.gsub(/\s+/, "")
  end

  def numeric(cell)
    text = cell.to_s.strip
    return nil if text.blank?

    number = Float(text, exception: false)
    return text if number.nil? # #REF! 之類的字串原樣保留，由頁面呈現

    number % 1 == 0 ? number.to_i : number
  end

  def to_date(cell)
    case cell
    when Date, Time, DateTime then cell.to_date
    when String
      m = cell.strip.match(%r{\A(?:(\d{4})[/\-])?(\d{1,2})[/\-](\d{1,2})\z})
      return nil unless m

      Date.new((m[1] || Date.current.year).to_i, m[2].to_i, m[3].to_i)
    end
  rescue ArgumentError
    nil
  end
end
