require "roo"
require "digest"
require "json"

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

    def call
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

      book.sheets.each do |sheet_name|
        month = sheet_name.to_i
        if month <= 0 || month > 12
          month = @source_month || infer_month_from_filename
          next unless month
        end

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

          row_hash = ShoplineOrder.content_hash(
            order_number: order_number,
            product_name: payload[:product_name],
            quantity: payload[:quantity],
            checkout_amount: payload[:checkout_amount],
            total_amount: payload[:total_amount]
          )

          order = ShoplineOrder.find_or_initialize_by(source_row_hash: row_hash)
          order.assign_attributes(payload.compact)
          order.import_run_id = run.id
          order.raw = raw.compact if order.respond_to?(:raw=)
          order.save!

          upserted += 1
          progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
        rescue => e
          error_rows += 1
          run.add_error("orders sheet=#{sheet_name} row=#{row_i}: #{e.class} - #{e.message}")
          progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
        end

        log "[import] sheet=#{sheet_name} month=#{month} end"
      end

      run.update!(
        processed_rows: processed,
        upserted_rows: upserted,
        skipped_rows: skipped,
        error_rows: error_rows,
        error_messages: run.error_messages,
        finished_at: Time.zone.now
      )

      log "[import] done run_id=#{run.id} processed=#{processed} upserted=#{upserted} skipped=#{skipped} errors=#{error_rows}"
      run
    end

    private

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
        membership_level:  raw[:membership_level]&.to_s&.strip.presence || customer.membership_level,
        city:              raw[:city]&.to_s&.strip.presence || customer.city
      )

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
      BigDecimal(v.to_s) rescue nil
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