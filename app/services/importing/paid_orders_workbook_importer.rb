require "roo"
require "digest"
require "json"
require "set"
require Rails.root.join("lib/shopline_orders_maintenance_lock") if defined?(Rails)

module Importing
  class PaidOrdersWorkbookImporter
    HEADER_MAP = {
      "訂單號碼" => :order_number,
      "訂單日期" => :order_date,
      "顧客" => :customer_name,
      "商品名稱" => :product_name,
      "付款總金額" => :total_amount,
      "商品結帳價" => :checkout_amount, # ✅ 新增：你要的營收口徑
      "數量" => :quantity,
      "電話號碼" => :phone,
      "付款狀態" => :payment_status,
      "電郵" => :email,
      "ig帳號" => :instagram_account,
      "付款方式" => :payment_method,
      "會員等級" => :membership_level,
      "城市" => :city
    }.freeze

    PROGRESS_EVERY = 500

    def initialize(file_path:, source_year:, source_month: nil, only_payment_status: nil, verbose: true)
      @file_path = file_path
      @source_year = source_year.to_i
      @source_month = source_month&.to_i
      @only_payment_status = only_payment_status
      @verbose = verbose
    end

    # Acquires the shared ShoplineOrdersMaintenanceLock for the entire import
    # (released in an ensure inside try_with_lock) — a rehash or dedupe run
    # in progress holds the same lock, so this fails fast, loudly, and
    # before any ImportRun or row is written, rather than interleaving
    # writes with a maintenance operation that is rewriting the same table.
    # No retry/backoff: this importer is invoked manually via rake by a
    # human operator (see lib/tasks/import_paid_orders.rake) who sees the
    # error directly and can simply re-run once the maintenance window ends.
    def call
      acquired, result = ShoplineOrdersMaintenanceLock.try_with_lock { perform_import }
      return result if acquired

      raise Importing::ImportLockedError,
        "shopline_orders maintenance lock (#{ShoplineOrdersMaintenanceLock::NAME}) is held by a rehash or " \
        "dedupe run — import aborted before any write. Re-run once that finishes."
    end

    private

    def perform_import
      log "[import] start file=#{@file_path} year=#{@source_year} only_payment_status=#{@only_payment_status.inspect}"

      run = ImportRun.create!(
        kind: "paid_orders_workbook",
        file_name: File.basename(@file_path),
        file_checksum: Digest::SHA256.file(@file_path).hexdigest,
        meta: { source_year: @source_year, only_payment_status: @only_payment_status },
        started_at: Time.zone.now
      )

      log "[import] created ImportRun id=#{run.id}"
      log "[import] opening xlsx..."
      book = Roo::Spreadsheet.open(@file_path)
      log "[import] opened sheets=#{book.sheets.inspect}"

      processed = 0
      upserted = 0
      skipped = 0
      error_rows = 0
      # (order_number, content signature) => how many times seen so far in
      # this import run. Feeds ShoplineOrder.content_hash's `occurrence:` so
      # two genuinely-identical line items within one order get distinct
      # identities instead of collapsing into one. Scoped to the whole run
      # (not per-sheet) since re-imports of the same file must reproduce the
      # same counts to stay idempotent.
      occurrence_counts = Hash.new(0)
      touched_months = Set.new
      # 這次檔案裡出現、而且每一行都成功寫入的訂單號碼 → 匯入後以訂單為單位
      # 覆蓋（見 prune_stale_rows!）。任何一行出錯的訂單不覆蓋，避免把舊資料
      # 刪了、新資料又沒寫進去。
      seen_orders = Set.new
      failed_orders = Set.new

      book.sheets.each do |sheet_name|
        month = sheet_name.to_i
        if month <= 0 || month > 12
          month = @source_month || infer_month_from_filename
          next unless month
        end

        touched_months << month
        log "[import] sheet=#{sheet_name} month=#{month} begin"

        book.default_sheet = sheet_name
        headers = book.row(1).map { |h| h.to_s.strip }
        index = headers.each_with_index.to_h
        last = book.last_row || 1

        log "[import] sheet=#{sheet_name} rows=#{[last - 1, 0].max}"

        (2..last).each do |row_i|
          processed += 1
          row = book.row(row_i)

          raw = extract_row(row, index)
          order_number = raw[:order_number].to_s.strip

          if order_number.empty?
            skipped += 1
            progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
            next
          end

          if @only_payment_status && raw[:payment_status].to_s.strip != @only_payment_status
            skipped += 1
            progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
            next
          end

          customer = resolve_customer!(raw, run.id)
          payload = build_order_payload(raw, order_number, customer, month)

          signature = [
            order_number,
            ShoplineOrder.normalize_product_name(payload[:product_name]),
            payload[:quantity].to_i,
            ShoplineOrder.format_decimal(payload[:checkout_amount])
          ]
          occurrence_counts[signature] += 1

          row_hash = ShoplineOrder.content_hash(
            order_number: order_number,
            product_name: payload[:product_name],
            quantity: payload[:quantity],
            checkout_amount: payload[:checkout_amount],
            occurrence: occurrence_counts[signature]
          )

          order = ShoplineOrder.find_or_initialize_by(source_row_hash: row_hash)
          order.assign_attributes(payload.compact)
          order.import_run_id = run.id
          order.raw = raw.compact if order.respond_to?(:raw=)
          order.save!

          seen_orders << order_number
          upserted += 1
          progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
        rescue => e
          failed_orders << order_number if order_number.present?
          error_rows += 1
          run.add_error("orders sheet=#{sheet_name} row=#{row_i}: #{e.class} - #{e.message}")
          progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
        end

        log "[import] sheet=#{sheet_name} month=#{month} end"
      end

      pruned = prune_stale_rows!(run, seen_orders - failed_orders)

      canceled_candidates = touched_months.sort.flat_map do |month|
        Importing::CanceledOrderCandidates.call(year: @source_year, month: month).to_a
      end

      if canceled_candidates.any?
        log "[import] ⚠ #{canceled_candidates.size} order(s) still 已付款 in the DB for " \
          "#{touched_months.sort.join(',')}/#{@source_year} but absent from this file " \
          "(likely paid then canceled — review before purging):"
        canceled_candidates.each do |o|
          log "  - #{o.order_number} #{o.customer_name} #{o.product_name} #{o.checkout_amount} (#{o.order_date&.to_date})"
        end
        log "[import] review the list above, then run e.g. " \
          "`bin/rails \"import:purge_canceled_orders[#{@source_year},#{touched_months.sort.first}]\"` per month to remove them."
      end

      run.update!(
        processed_rows: processed,
        upserted_rows: upserted,
        skipped_rows: skipped,
        error_rows: error_rows,
        error_messages: run.error_messages,
        meta: run.meta.merge(
          "pruned_stale_rows" => pruned.size,
          "pruned_rows" => pruned.first(500),
          "canceled_candidates" => canceled_candidates.map { |o|
            {
              order_number: o.order_number,
              customer_name: o.customer_name,
              product_name: o.product_name,
              checkout_amount: o.checkout_amount&.to_s,
              order_date: o.order_date&.to_date&.to_s
            }
          }
        ),
        finished_at: Time.zone.now
      )

      log "[import] done run_id=#{run.id} processed=#{processed} upserted=#{upserted} skipped=#{skipped} errors=#{error_rows}"
      run
    end

    # 以訂單為單位覆蓋：檔案裡有的訂單，以這次檔案的內容為準。
    #
    # 每一行的身分是 order_number＋商品名稱＋數量＋結帳價（ShoplineOrder.content_hash），
    # 但 Shopline 每次匯出的商品名稱會變（「薑黃6」→「薑黃6送1」、「冰晶蕃茄5」→
    # 「冰晶番茄5送1」、SKU 改名、組合順序互換），數量／金額也可能被改。名稱一變，
    # find_or_initialize_by 找不到舊列就新增一列，舊列永遠留著 → 同一張單新舊兩版
    # 並存、營收重複計算（2026/10/20 正式站一次清出 474 列、約 $541 萬）。
    #
    # 這裡只刪「這次檔案裡有出現的訂單」底下、這次沒被寫到的列：訂單本身確定還在，
    # 這些列只是舊版內容，所以即使上傳的是不完整的檔案（例如只匯一天）也安全。
    # 整張訂單都不在檔案裡的（可能是取消，也可能只是檔案不完整）不在這裡處理，
    # 仍走 canceled_candidates ＋ import:purge_canceled_orders 人工確認。
    def prune_stale_rows!(run, order_numbers)
      pruned = []
      order_numbers.each_slice(1000) do |batch|
        stale = ShoplineOrder
          .where(order_number: batch)
          .where("import_run_id IS NULL OR import_run_id <> ?", run.id)
        stale.order(:order_number, :id).each do |o|
          pruned << {
            "order_number" => o.order_number,
            "product_name" => o.product_name,
            "quantity" => o.quantity,
            "checkout_amount" => o.checkout_amount&.to_s,
            "order_date" => o.order_date&.to_date&.to_s,
            "import_run_id" => o.import_run_id
          }
        end
        stale.delete_all
      end

      if pruned.any?
        log "[import] replaced #{pruned.size} stale row(s) in orders present in this file (renamed/changed lines from earlier imports)"
      end
      pruned
    end

    def infer_month_from_filename
      File.basename(@file_path, ".*")
        .scan(/\b(\d{1,2})\b/)
        .flatten
        .map(&:to_i)
        .find { |n| n >= 1 && n <= 12 }
    end

    def extract_row(row, index)
      out = {}
      HEADER_MAP.each do |header, key|
        i = index[header]
        out[key] = i ? row[i] : nil
      end
      out
    end

    def build_order_payload(raw, order_number, customer, month)
      {
        order_number: order_number,
        product_name: raw[:product_name]&.to_s&.strip,
        email: ShoplineCustomer.normalize_email(raw[:email]),
        instagram_account: ShoplineCustomer.normalize_ig(raw[:instagram_account]),
        payment_status: raw[:payment_status]&.to_s&.strip,
        total_amount: to_decimal(raw[:total_amount]),             # 付款總金額（保留）
        checkout_amount: to_decimal(raw[:checkout_amount]),       # ✅ 商品結帳價（你要拿來算營收）
        quantity: safe_int(raw[:quantity]),
        customer_name: raw[:customer_name]&.to_s&.strip,
        payment_method: raw[:payment_method]&.to_s&.strip,
        order_date: order_date_for(order_number, raw[:order_date]),
        membership_level: raw[:membership_level]&.to_s&.strip,
        city: raw[:city]&.to_s&.strip,                            # ✅ 城市寫進 order
        source_year: @source_year,
        source_month: month,
        shopline_customer_id: customer&.id
      }
    end

    def resolve_customer!(raw, import_run_id)
      email  = ShoplineCustomer.normalize_email(raw[:email])
      phone  = ShoplineCustomer.normalize_phone(raw[:phone])
      ig     = ShoplineCustomer.normalize_ig(raw[:instagram_account])

      customer =
        if email
          ShoplineCustomer.find_or_initialize_by(email: email)
        elsif phone
          # mobile_phone 才是正確欄位
          ShoplineCustomer.find_or_initialize_by(mobile_phone: phone)
        elsif ig
          ShoplineCustomer.find_or_initialize_by(instagram_account: ig)
        end

      return nil unless customer

      customer.assign_attributes(
        full_name:         raw[:customer_name]&.to_s&.strip.presence || customer.full_name,
        email:             email || customer.email,
        mobile_phone:      phone || customer.mobile_phone,  # ← 改這裡
        instagram_account: ig || customer.instagram_account,
        city:              raw[:city]&.to_s&.strip.presence || customer.city
      )
      # membership_level 不從訂單檔回填：訂單上的「會員等級」是下單當下的歷史快照，
      # 重跑舊訂單檔會用過期的卡別覆蓋掉會員報表剛同步好的目前卡別，之前因此讓同一次
      # 真實升降級被 MembershipLevelChange 重複記錄。目前卡別只由 CustomersReportImporter 更新。

      customer.import_run_id = import_run_id if customer.respond_to?(:import_run_id=)
      if customer.respond_to?(:source_row_hash) && customer.source_row_hash.blank?
        customer.source_row_hash = Digest::SHA256.hexdigest(
          JSON.generate(kind: "order_resolved_customer", payload: { email: email, phone: phone, ig: ig })
        )
      end
      customer.raw = (customer.raw || {}).merge(raw.compact) if customer.respond_to?(:raw=)

      customer.save!
      customer
    end

    def progress(run, processed, upserted, skipped, error_rows, sheet_name)
      log "[import] processed=#{processed} upserted=#{upserted} skipped=#{skipped} errors=#{error_rows} (sheet=#{sheet_name})"
      run.update!(
        processed_rows: processed,
        upserted_rows: upserted,
        skipped_rows: skipped,
        error_rows: error_rows,
        error_messages: run.error_messages
      )
    rescue => e
      log "[import] progress_update_failed: #{e.class} - #{e.message}"
    end

    def log(msg)
      puts msg if @verbose
    end

    def to_decimal(v)
      return nil if v.nil?

      # Strip thousands separators ("2,670") before parsing — without this,
      # a comma-formatted cell silently becomes nil instead of a value,
      # which would otherwise change this line's content_hash signature
      # every time the source formatting varies and create a duplicate row.
      cleaned = v.to_s.strip.delete(",")
      return nil if cleaned.blank?

      BigDecimal(cleaned)
    rescue ArgumentError
      nil
    end

    def safe_int(v)
      i = v.to_i
      i <= 0 ? 1 : i
    end

    def to_time(v)
      return nil if v.nil?
      return v if v.is_a?(Time) || v.is_a?(DateTime)
      return v.to_time if v.is_a?(Date)
      Time.zone.parse(v.to_s) rescue nil
    end

    # 訂單號碼內嵌下單時間（#YYYYMMDDHHMMSS…），但那是 UTC 時間；
    # 加 8 小時才是台灣（Asia/Taipei）的下單日期，Excel 的「訂單日期」也是台灣日期。
    # 一律以台灣日期為準，訂單號碼解析不出來才退回 Excel 的值。
    def order_date_for(order_number, raw_date)
      m = order_number.match(/\A#(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/)
      return to_time(raw_date) unless m

      utc = Time.utc(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i)
      local_date = (utc + 8 * 3600).to_date
      Time.utc(local_date.year, local_date.month, local_date.day)
    rescue ArgumentError
      to_time(raw_date)
    end
  end
end