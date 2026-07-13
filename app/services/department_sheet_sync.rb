# frozen_string_literal: true

require "open-uri"

# 從各部門的 Google Sheet（開啟「知道連結的人可檢視」）下載 xlsx，
# 解析每日工作日誌後 upsert 進 department_updates。
#
# 工作表格式慣例：
# - 每月一個分頁（分頁名稱為月份數字，例如 "7"）
# - 內容列以「日期」欄起頭（xlsx 內為真正的日期儲存格）；
#   日期空白的列延續前一天的內容
# - 「日期,星期,...」為欄位標題列，之後的欄位標題拿來當內容標籤；
#   標題列可能在同一分頁內重複出現
class DepartmentSheetSync
  SHEETS = {
    "廣告部" => "13coB3H8g0-s3I7GVFw3Rsc4jzupyJplAwf7nKoZJcUg",
    "編輯部" => "1VhtDicT0xJYZ4sWC0OscTWQ2QQlb-WaSdNwFuJvbFAY", # 檔名「總編輯」
    "社群部" => "1ZubEE8B653-zqMyf_hnm2HrEyeU6Ntoo0YYC_mywblU",
    "CRM"    => "1BAJbJsd4-6VQDxnTtyw1IO9vdP0dTeX1GBXL-VFew-Y",
    "數據部" => "1KM-xL0FKU0HC25gMcu_amg9Lrx9rB1Tb7yw_LEmu5Go",
    "設計部" => "1zL4tu9HEBZKpthUQBZTzwLHRHacfdiDldqvM9Nk7_gY",
    "物流部" => "1Y9MPquXE_BQmOBtx2ICaDYn4wxPZqgqjP6WOnYAdk8w",
    "財務部" => "1qigqO90cbiCSEmDG9RqKAUN6TuArMwap2xQmtKsq6PA"
  }.freeze

  LAST_RUN_CACHE_KEY = "department_sheet_sync/last_run_at"
  LAST_RESULT_CACHE_KEY = "department_sheet_sync/last_result"
  MAX_CONTENT_LENGTH = 6000

  class << self
    # cache store 不可用時（例如 dev 的 null_store）的程序內備援，
    # 避免每個 request 都觸發一次背景同步
    attr_accessor :memory_last_run_at
  end

  def self.call
    new.call
  end

  def call
    run = SyncRun.create!(source: "department_sheets", started_at: Time.current)

    results = SHEETS.to_h do |department, sheet_id|
      [department, sync_department(department, sheet_id)]
    end

    failed = results.count { |_, r| r[:error].present? }
    run.update!(
      status:         failed.zero? ? "success" : (failed == results.size ? "failed" : "partial"),
      finished_at:    Time.current,
      meta:           results,
      error_messages: results.filter_map { |dept, r| "#{dept}: #{r[:error]}" if r[:error] }
    )

    self.class.mark_run!
    Rails.cache.write(LAST_RESULT_CACHE_KEY, results)
    results
  end

  def self.last_run_at
    [
      SyncRun.last_finished_at("department_sheets"),
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

  def sync_department(department, sheet_id)
    xlsx = download_workbook(sheet_id)
    days = {}
    xlsx.sheets.each do |sheet_name|
      parse_sheet(xlsx.sheet(sheet_name), days)
    end

    days.each do |date, lines|
      content = lines.join("\n").strip[0, MAX_CONTENT_LENGTH]
      next if content.blank?

      DepartmentUpdate
        .find_or_initialize_by(department: department, log_date: date)
        .update!(content: content)
    end

    { dates: days.size, error: nil }
  rescue StandardError => e
    Rails.logger.error("[DepartmentSheetSync] #{department}: #{e.class} #{e.message}")
    { dates: 0, error: "#{e.class}: #{e.message}" }
  end

  def download_workbook(sheet_id)
    url = "https://docs.google.com/spreadsheets/d/#{sheet_id}/export?format=xlsx"
    io = URI.parse(url).open(open_timeout: 15, read_timeout: 60)
    file = Tempfile.new(["dept_sheet", ".xlsx"], binmode: true)
    file.write(io.read)
    file.rewind
    Roo::Excelx.new(file.path)
  end

  def parse_sheet(sheet, days)
    labels = []
    current_date = nil

    (sheet.first_row..sheet.last_row).each do |row_index|
      row = sheet.row(row_index)
      first = row[0]

      if header_row?(first)
        labels = row.map { |c| c.to_s.strip }
        current_date = nil unless current_date # 標題列重複出現時保留目前日期
        next
      end

      date = extract_date(first)
      current_date = date if date
      next if current_date.nil?

      lines = row_lines(row, labels, date_cell_used: !date.nil?)
      (days[current_date] ||= []).concat(lines)
    end
  end

  def header_row?(cell)
    cell.to_s.strip == "日期"
  end

  def extract_date(cell)
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

  def row_lines(row, labels, date_cell_used:)
    lines = []
    row.each_with_index do |cell, index|
      next if index.zero? && date_cell_used     # 日期本身
      next if labels[index].to_s.strip == "星期"

      text = cell.to_s.strip
      next if text.blank? || text == "nil"

      label = labels[index].to_s.strip
      lines << (label.present? && label != "日期" ? "【#{label}】#{text}" : text)
    end
    lines
  end
end
