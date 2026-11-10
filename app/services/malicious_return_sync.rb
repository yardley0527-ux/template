# frozen_string_literal: true

require "open-uri"

# 財務的「退貨／折讓」表（Google Drive，開「知道連結的人可檢視」）裡標「惡意退貨」的客人，
# 自動勾 customer_profiles.blacklisted。黑名單之後由 MessageListBuilder 等既有機制排除。
# 還在黑名單的這些客人，每次同步也會：
# - 拿掉退貨產品的標籤（購買過苼莛的產品／產品偏好）。退貨品項看「退貨商品」欄，
#   沒寫產品（「尚未出貨」等）就看「原購買商品」，都沒有就看訂單本身的品名
# - 從所有訊息名單（含已傳過的舊名單）刪掉本人和同 IG 的其他帳號
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
  RETURNED_COL = 10 # 退貨商品
  ORIGINAL_COL = 8  # 原購買商品

  # 品名關鍵字 → 標籤（CustomerProfile::SHENGTING_PRODUCT_OPTIONS 的寫法）。照順序比對。
  PRODUCT_TAGS = [
    [/PDRN|鮭魚精華/i, "PDRN"],
    [/冰晶/, "冰晶番茄"],
    [/白藜蘆醇/, "白藜蘆醇"],
    [/代謝/, "代謝錠"],
    [/清纖/, "清纖粉"],
    [/私密/, "私密粉"],
    [/益生菌/, "益生菌"],
    [/全能|B群/, "全能"],
    [/薑黃/, "薑黃"],
    [/膠原/, "膠原蛋白"],
    [/穀胱甘肽/, "穀胱甘肽"],
    [/蝦紅素/, "蝦紅素"],
    [/魚油/, "魚油"],
    [/維(生素)?D|維DK/, "維DK鈣"]
  ].freeze

  # 品名 → 標籤；冰晶番茄的品名裡有「白藜蘆醇」，不算白藜蘆醇
  def self.tags_for(text)
    tags = PRODUCT_TAGS.filter_map { |re, tag| tag if text.to_s.match?(re) }
    tags.delete("白藜蘆醇") if tags.include?("冰晶番茄")
    tags.include?("私密粉") ? tags - ["益生菌"] : tags # 私密益生菌＝私密粉
  end

  # rows: 測試用，直接給二維陣列就不下載
  def self.call(rows: nil) = new.call(rows: rows)

  def call(rows: nil)
    run = SyncRun.create!(source: "malicious_returns", started_at: Time.current)
    result = apply(parse(rows || download_rows))
    result.merge!(cleanup(result[:entries]))
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

      tags = self.class.tags_for(row[RETURNED_COL]).presence || self.class.tags_for(row[ORIGINAL_COL])
      { orders: orders, emails: emails, label: (orders + emails).join(" "), tags: tags,
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
      tags = entry[:tags].presence ||
             self.class.tags_for(ShoplineOrder.where(order_number: entry[:orders]).pluck(:product_name).join(" "))
      details << entry.except(:label).merge(tags: tags, customer_ids: customers.map(&:id))
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

  # 還在黑名單（且是這裡自動處理過的）客人：拿掉退貨產品標籤、從所有訊息名單刪掉
  def cleanup(entries)
    tags_by_customer = Hash.new { |h, k| h[k] = [] }
    entries.each { |e| e[:customer_ids].each { |id| tags_by_customer[id] |= e[:tags] } }

    active_ids = CustomerProfile.where(shopline_customer_id: tags_by_customer.keys, blacklisted: true)
                                .where(shopline_customer_id: CustomerEditLog.where(section: LOG_SECTION).select(:customer_id))
                                .pluck(:shopline_customer_id)
    customers = ShoplineCustomer.where(id: active_ids).includes(:customer_profile).to_a

    tags_removed = {}
    customers.each do |c|
      removed = remove_tags(c, tags_by_customer[c.id])
      tags_removed[c.full_name.presence || c.email] = removed if removed.any?
    end

    { tags_removed: tags_removed, recipients_removed: purge_message_lists(customers) }
  end

  def remove_tags(customer, tags)
    profile = customer.customer_profile
    before = { "shengting_product_tags" => profile.shengting_product_tags, "product_tags" => profile.product_tags }
    profile.shengting_product_tags -= tags
    profile.product_tags -= tags
    return [] unless profile.changed?

    profile.save!
    changes = before.select { |field, was| profile[field] != was }.to_h { |field, was| [field, [was, profile[field]]] }
    CustomerEditLog.create!(customer_id: customer.id, customer_name: customer.full_name, section: LOG_SECTION,
                            changes_json: changes)
    before.values.flatten.uniq - profile.shengting_product_tags - profile.product_tags
  end

  # 本人＋同 IG 的其他帳號，所有訊息名單（不分新舊）都刪掉；回傳 名字 → 刪掉的名單數
  def purge_message_lists(customers)
    return {} if customers.empty?

    igs = customers.filter_map { |c| MessageListBuilder.normalize_ig(c.instagram_account) }
                   .reject { |ig| ig.length < 3 || %w[nil null n/a na no 無].include?(ig) }
    related = customers.dup
    related += ShoplineCustomer.where("LOWER(TRIM(instagram_account)) IN (?)", igs).to_a if igs.any?
    ids = related.map(&:id).uniq
    emails = related.filter_map { |c| c.email.to_s.strip.downcase.presence }.uniq

    scope = MessageListRecipient.where(shopline_customer_id: ids)
    scope = scope.or(MessageListRecipient.where("LOWER(TRIM(email)) IN (?)", emails)) if emails.any?
    rows = scope.pluck(:id, :full_name, :email)
    return {} if rows.empty?

    MessageListRecipient.where(id: rows.map(&:first)).delete_all
    rows.group_by { |_, name, email| name.presence || email }.transform_values(&:size)
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
