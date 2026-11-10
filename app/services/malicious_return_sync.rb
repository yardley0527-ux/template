# frozen_string_literal: true

require "open-uri"

# 財務的「退貨／折讓」表（Google Drive，開「知道連結的人可檢視」）裡標「惡意退貨」的客人，
# 自動勾 customer_profiles.blacklisted。黑名單之後由 MessageListBuilder 等既有機制排除。
#
# 表格每月一段、欄位會位移、後半年常沒填 email，所以不靠欄位位置：
# 任一格是「惡意退貨」的列就算，從整列抓訂單號碼（#+17 碼）和 email，
# 先用訂單號碼對 shopline_orders 找客人，再加上表上的 email。
#
# 每個客人只自動處理一次（留一筆 section=malicious_return 的 CustomerEditLog）：
# 有人手動把黑名單取消，下次同步不會再勾回去。
# 對不到的列（訂單還沒匯入、沒單號也沒 email）不留紀錄，下次同步會再試。
#
# 觸發：rake ops:sync（Render Cron）＋ 每次匯入已付款訂單後（ImportPaidOrdersJob）。
class MaliciousReturnSync
  FILE_ID = "1h2xZeaiAqTXCB8-t33W85yTHHl2pidn_"
  URL = "https://docs.google.com/spreadsheets/d/#{FILE_ID}/export?format=xlsx"
  SHEET_URL = "https://docs.google.com/spreadsheets/d/#{FILE_ID}/edit"
  MARK = "惡意退貨"
  LOG_SECTION = "malicious_return"
  ORDER_RE = /#?\s*(\d{17})/
  EMAIL_RE = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/

  # rows: 測試用，直接給二維陣列就不下載
  def self.call(rows: nil) = new.call(rows: rows)

  def call(rows: nil)
    run = SyncRun.create!(source: "malicious_returns", started_at: Time.current)
    result = apply(parse(rows || download_rows))
    run.update!(status: result[:unmatched].empty? ? "success" : "partial", finished_at: Time.current,
                meta: result, error_messages: result[:unmatched].map { |u| "對不到客人：#{u}" })
    result
  rescue StandardError => e
    run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
    { error: e.message }
  end

  # 標「惡意退貨」的列 → [{ orders: [...], emails: [...], label: "..." }]
  def parse(rows)
    rows.filter_map do |row|
      cells = row.map { |c| c.to_s.strip }
      next unless cells.include?(MARK)

      text = cells.join(" ")
      orders = text.scan(ORDER_RE).flatten.map { |n| "##{n}" }.uniq
      emails = text.scan(EMAIL_RE).map(&:downcase).uniq
      next if orders.empty? && emails.empty?

      { orders: orders, emails: emails, label: (orders + emails).join(" "),
        name: row[4].to_s.strip.presence, date: row.find { |c| c.is_a?(Date) }&.iso8601 }
    end
  end

  # 頁面用：最後一次成功同步的逐列結果
  def self.latest_run = SyncRun.where(source: "malicious_returns", status: %w[success partial]).order(:created_at).last

  private

  def download_rows
    io = URI.parse(URL).open(open_timeout: 15, read_timeout: 60)
    Tempfile.create(["malicious_returns", ".xlsx"], binmode: true) do |file|
      IO.copy_stream(io, file)
      file.flush
      book = Roo::Excelx.new(file.path)
      book.sheets.flat_map do |name|
        sheet = book.sheet(name)
        sheet.last_row ? (1..sheet.last_row).map { |i| sheet.row(i) } : []
      end
    end
  end

  def apply(entries)
    added = []
    already = 0
    unmatched = []
    details = []

    entries.each do |entry|
      customers = customers_for(entry)
      details << entry.except(:label).merge(customer_ids: customers.map(&:id))
      if customers.empty?
        unmatched << entry[:label]
        next
      end

      customers.each do |customer|
        next if CustomerEditLog.exists?(customer_id: customer.id, section: LOG_SECTION)

        profile = CustomerProfile.find_or_create_by!(shopline_customer_id: customer.id)
        was = profile.blacklisted
        profile.update!(blacklisted: true) unless was
        was ? already += 1 : added << (customer.full_name.presence || customer.email)

        CustomerEditLog.create!(
          customer_id: customer.id, customer_name: customer.full_name, section: LOG_SECTION,
          changes_json: { "blacklisted" => [was, true], "malicious_return_orders" => [nil, entry[:orders]] }
        )
      end
    end

    { rows: entries.size, added: added, already_blacklisted: already, unmatched: unmatched, entries: details }
  end

  def customers_for(entry)
    from_orders = ShoplineOrder.where(order_number: entry[:orders]).pluck(:shopline_customer_id, :email)
    ids = from_orders.filter_map(&:first)
    emails = (entry[:emails] + from_orders.filter_map { |_, e| e.to_s.strip.downcase.presence }).uniq

    scope = ShoplineCustomer.where(id: ids)
    scope = scope.or(ShoplineCustomer.where("LOWER(TRIM(email)) IN (?)", emails)) if emails.any?
    scope.to_a
  end
end
