# frozen_string_literal: true

# 把 DANDY 庫存表（DandyInventorySnapshot，DandyInventorySync 同步進來的原始資料）
# 的「即時庫存」數字，套進 crm_products.availability_status——取代原本完全
# 靠人工在 /product_registry 維護的流程（8/23 才發現冰晶番茄卡在 unknown
# 一個多月沒人更新，導致高分族/破萬未二購規則一直推薦缺貨產品）。
#
# NOTE：CrmProduct 原本的設計理念是「庫存狀態變更必須由使用者明確操作」
# （model 註解：actual_restock_date/expected_restock_date 都不會自動觸發變更）。
# 這支 service 是使用者 2026-08-24 明確要求的例外——只信任下面
# NAME_TO_KEY 裡「有把握」的品名對應，對不到的品名（例如「上錠下液」
# 「美容儀」「外泌體面膜」）一律跳過不猜，避免自動化反而把庫存狀態改錯。
# 每次變更都走 CrmProduct 既有的 PaperTrail（審計歷史一樣看得到是誰/什麼
# 時候改的，只是這次的「使用者」是系統本身，inventory_status_updated_by_id
# 留空跟人工操作區分開來）。
class CrmProductInventorySync
  # DANDY 表品名 → crm_products.key。只放「名稱對應無歧義」的品項；
  # 其餘（上錠下液/美容儀/外泌體面膜等）故意不放，交給人工在 /product_registry 確認。
  NAME_TO_KEY = {
    "全能B群"   => "omnipotent",
    "冰晶番茄"   => "iced_tomato",
    "膠原蛋白"   => "collagen",
    "維生素D+鈣" => "vitamin_dk_calcium",
    "蝦紅素"     => "astaxanthin",
    "代謝錠"     => "metabolism",
    "清纖粉"     => "cleanse_powder",
    "益生菌"     => "probiotic",
    "私密"       => "intimate_powder",
    "薑黃"       => "turmeric",
    "魚油"       => "fish_oil"
  }.freeze

  LOW_STOCK_THRESHOLD = 50 # 即時庫存 < 這個數字視為低庫存（非 0）；可再調整
  ARRIVAL_DATE_PATTERN = /(\d{1,2})\/(\d{1,2})\s*到貨/

  def self.call
    new.call
  end

  def call
    snapshot = DandyInventorySnapshot.latest
    return { error: "no DandyInventorySnapshot yet" } if snapshot.nil?

    run = SyncRun.create!(source: "crm_product_inventory", started_at: Time.current)
    updated = []
    skipped_unmapped = []

    rows_by_name(snapshot).each do |name, row|
      key = NAME_TO_KEY[name]
      next skipped_unmapped << name if key.nil?

      product = CrmProduct.find_by(key: key)
      next if product.nil?

      change = apply_row!(product, row, snapshot)
      updated << change if change
    end

    run.update!(status: "success", finished_at: Time.current,
               meta: { updated_count: updated.size, updated: updated, unmapped_names: skipped_unmapped.uniq,
                       snapshot_date: snapshot.snapshot_date.to_s })
    { error: nil, updated: updated, unmapped_names: skipped_unmapped.uniq }
  rescue StandardError => e
    run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
    { error: "#{e.class}: #{e.message}" }
  end

  private

  def rows_by_name(snapshot)
    (snapshot.supplements["rows"] || []).index_by { |r| r["name"] }
  end

  def apply_row!(product, row, snapshot)
    stock = row["values"]&.compact&.last # 最後一個非 null 值＝「即時庫存」欄（見 DandyInventorySync::SUPPLEMENT_COLUMNS）
    return nil if stock.nil?

    new_status = status_for(stock)
    restock_date = parse_arrival_date(row["arrival"])

    changed = new_status != product.availability_status
    return nil unless changed || (restock_date && restock_date != product.expected_restock_date)

    old_status = product.availability_status
    product.availability_status = new_status
    product.expected_restock_date = restock_date if restock_date
    product.inventory_status_updated_at = Time.current
    product.inventory_note = [
      product.inventory_note.presence,
      "#{snapshot.snapshot_date}: DANDY庫存表自動同步，即時庫存=#{stock}" \
      "#{restock_date ? "，預定到貨#{restock_date}" : ''}" \
      "#{changed ? "，狀態 #{old_status} → #{new_status}" : ''}"
    ].compact.join("\n")
    product.save!

    { key: product.key, old_status: old_status, new_status: new_status, stock: stock }
  end

  def status_for(stock)
    return "out_of_stock" if stock.zero?
    return "low_stock" if stock < LOW_STOCK_THRESHOLD

    "in_stock"
  end

  # 目前只看得懂「8/21 到貨」這種常見格式；其他自由文字（例如純備註）不解析，
  # 保留 nil 讓呼叫端跳過 expected_restock_date 更新，不強行猜測。
  def parse_arrival_date(arrival)
    return nil if arrival.blank?

    match = ARRIVAL_DATE_PATTERN.match(arrival)
    return nil unless match

    month, day = match[1].to_i, match[2].to_i
    year = Date.current.year
    date = Date.new(year, month, day)
    date += 1.year if date < Date.current - 30 # 明顯是「今年已過很久」時，視為指明年
    date
  rescue ArgumentError
    nil
  end
end
