# path: app/services/importing/customers_report_importer.rb
# frozen_string_literal: true

require "roo"
require "digest"
require "json"

module Importing
  class CustomersReportImporter
    PROGRESS_EVERY = 500
    BATCH_SIZE = 300

    def initialize(file_path:, sheet: 0, header_row: 1, verbose: true)
      @file_path = file_path
      @sheet = sheet
      @header_row = header_row
      @verbose = verbose
    end

    def call
      log "[import] start file=#{@file_path} sheet=#{@sheet} header_row=#{@header_row}"

      run = ImportRun.create!(
        kind: "customers_report",
        file_name: File.basename(@file_path),
        file_checksum: Digest::SHA256.file(@file_path).hexdigest,
        meta: { sheet: @sheet, header_row: @header_row },
        started_at: Time.zone.now
      )

      log "[import] created ImportRun id=#{run.id}"
      log "[import] opening xls/xlsx..."
      book = Roo::Spreadsheet.open(@file_path)
      sheet_name = @sheet.is_a?(Integer) ? book.sheets.fetch(@sheet) : @sheet.to_s
      book.default_sheet = sheet_name
      log "[import] opened sheet=#{sheet_name}"

      headers = book.row(@header_row).map { |h| normalize_header(h) }
      last = book.last_row || @header_row
      log "[import] rows=#{[last - @header_row, 0].max} headers=#{headers.inspect}"

      processed = 0
      upserted = 0
      skipped = 0
      error_rows = 0

      shopline_batch = []
      email_batch    = []

      flush = lambda do
        begin
          if shopline_batch.any?
            ShoplineCustomer.upsert_all(
              shopline_batch,
              unique_by: :shopline_id,
              update_only: upsertable_columns
            )
            upserted += shopline_batch.size
          end
        rescue => e
          error_rows += shopline_batch.size
          run.add_error("upsert shopline_batch failed: #{e.class} - #{e.message}")
        ensure
          shopline_batch.clear
        end

        begin
          if email_batch.any?
            ShoplineCustomer.upsert_all(
              email_batch,
              unique_by: :email,
              update_only: upsertable_columns
            )
            upserted += email_batch.size
          end
        rescue => e
          error_rows += email_batch.size
          run.add_error("upsert email_batch failed: #{e.class} - #{e.message}")
        ensure
          email_batch.clear
        end
      end

      now = Time.zone.now

      ((@header_row + 1)..last).each do |row_i|
        processed += 1
        row = book.row(row_i)
        raw = headers.each_with_index.to_h { |k, idx| [k, row[idx]] }

        payload = map_payload(raw)
        shopline_id = normalize_id_cell(payload[:shopline_id])
        email = ShoplineCustomer.normalize_email(payload[:email])

        if shopline_id.nil? && email.nil?
          skipped += 1
          progress(run, processed, upserted, skipped, error_rows, sheet_name) if (processed % PROGRESS_EVERY).zero?
          next
        end

        payload[:email]       = email
        payload[:shopline_id] = shopline_id
        payload[:mobile_phone] = ShoplineCustomer.normalize_phone(normalize_phone_cell(payload[:mobile_phone]))
        payload[:phone]        = ShoplineCustomer.normalize_phone(normalize_phone_cell(payload[:phone])) if payload.key?(:phone)
        payload[:instagram_account] = ShoplineCustomer.normalize_ig(payload[:instagram_account]) if payload.key?(:instagram_account)

        row_hash = Digest::SHA256.hexdigest(
          JSON.generate(
            kind: run.kind,
            file_checksum: run.file_checksum,
            sheet: sheet_name,
            row_index: row_i,
            identity: { shopline_id: shopline_id, email: email },
            payload: payload.compact
          )
        )

        record = payload.compact.merge(
          import_run_id:   run.id,
          source_row_hash: row_hash,
          updated_at:      now,
          created_at:      now
        )

        if shopline_id
          shopline_batch << record
        else
          email_batch << record
        end

        if (shopline_batch.size + email_batch.size) >= BATCH_SIZE
          flush.call
          progress(run, processed, upserted, skipped, error_rows, sheet_name)
        end

      rescue => e
        error_rows += 1
        run.add_error("customers sheet=#{sheet_name} row=#{row_i}: #{e.class} - #{e.message}")
      end

      flush.call

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

    def log(msg)
      puts msg if @verbose
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

    # 對應 schema 實際有的欄位，排除 unique key (shopline_id / email) 與 created_at
    def upsertable_columns
      %i[
        full_name
        mobile_phone
        phone
        instagram_account
        order_count
        membership_level
        total_amount
        birthdate
        line_id
        issued_shopping_credits
        used_shopping_credits
        current_shopping_credits
        member_registered_at
        address_1
        address_2
        city
        import_run_id
        source_row_hash
        updated_at
      ]
    end

    # Unicode-aware: keeps Chinese headers (電郵/全名/顧客 ID...)
    def normalize_header(h)
      h.to_s.strip.downcase
        .gsub(/[[:space:]]+/, "_")
        .gsub(/[^\p{L}\p{N}_]+/u, "")
    end

    def map_payload(raw)
      get = ->(*keys) do
        keys.each do |k|
          v = raw[k]
          return v if v.present?
        end
        nil
      end

      {
        shopline_id:               get.call("顧客_id", "顧客id", "customer_id", "shopline_id", "id"),
        full_name:                 get.call("全名", "full_name", "name"),
        email:                     get.call("電郵", "email"),
        order_count:               to_int(get.call("訂單數", "order_count")),
        membership_level:          get.call("會員級別", "membership_level"),
        instagram_account:         get.call("ig帳號", "instagram_account", "ig"),
        total_amount:              to_decimal(get.call("累積金額", "total_amount")),
        birthdate:                 to_date(get.call("生日", "birthdate")),
        line_id:                   get.call("line_註冊_id", "line_id", "line註冊id"),
        mobile_phone:              get.call("會員綁定手機號碼", "mobile_phone"),
        issued_shopping_credits:   to_decimal(get.call("已發放購物金", "issued_shopping_credits")),
        used_shopping_credits:     to_decimal(get.call("已使用購物金", "used_shopping_credits")),
        current_shopping_credits:  to_decimal(get.call("現有購物金", "current_shopping_credits")),
        member_registered_at:      to_time(get.call("會員註冊日期", "member_registered_at")),
        address_1:                 get.call("地址_1", "address_1"),
        address_2:                 get.call("地址_2", "address_2"),
        city:                      get.call("城市", "city")
      }
    end

    # Roo 會把純數字欄位讀成 Float（例如 12345.0），
    # 統一轉成整數字串避免 upsert 時用 "12345.0" 去比對
    def normalize_id_cell(v)
      return nil if v.nil?

      if v.is_a?(Float)
        v.to_i.to_s
      else
        v.to_s.sub(/\.0\z/, "").strip
      end.presence
    end

    def normalize_phone_cell(v)
      return nil if v.nil?

      if v.is_a?(Float)
        v = v.to_i.to_s
      else
        v = v.to_s
        v = v.sub(/\.0\z/, "")
      end

      v.strip.presence
    end

    def to_int(v)
      return nil if v.nil?
      v.to_i
    end

    def to_decimal(v)
      return nil if v.nil?
      s = v.to_s.strip
      return nil if s.blank?

      s = s.gsub(/[[:space:]]+/, "")
      s = s.gsub(/nt\$/i, "")
      s = s.gsub("$", "")
      s = s.gsub(",", "")

      BigDecimal(s)
    rescue ArgumentError
      nil
    end

    def to_time(v)
      return nil if v.nil?
      return v if v.is_a?(Time) || v.is_a?(DateTime)
      return v.to_time if v.is_a?(Date)
      Time.zone.parse(v.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def to_date(v)
      return nil if v.nil?
      return v if v.is_a?(Date)

      s = v.to_s.strip
      return nil if s.blank?

      if s.match?(/\A\d{2}-\d{2}-\d{4}\z/)
        d, m, y = s.split("-").map(&:to_i)
        return Date.new(y, m, d)
      end

      Date.parse(s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end