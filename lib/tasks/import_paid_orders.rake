# path: lib/tasks/import_paid_orders.rake
# frozen_string_literal: true

namespace :import do
  desc <<~DESC
    Import paid orders workbook (.xlsx) or single-month CSV (.csv).

    Usage:
      DISABLE_SPRING=1 bundle exec rails "import:paid_orders[/path/file.xlsx,2024]"
      DISABLE_SPRING=1 bundle exec rails "import:paid_orders[/path/file.csv,2026,1]"

    For XLSX: sheet names must be month numbers (1–12).
    For CSV: pass the month as the third argument, or name the file with the month
             (e.g. "2026已付款訂單 - 1.csv" → inferred as month 1).
  DESC
  task :paid_orders, [:file, :year, :month] => :environment do |_t, args|
    raw_file = args[:file].to_s
    raw_year = args[:year].to_s
    raw_month = args[:month].to_s.strip

    file = File.expand_path(raw_file)
    year = raw_year.to_i
    month = raw_month.present? ? raw_month.to_i : nil

    puts(
      "[task] raw_file=#{raw_file.inspect} expanded_file=#{file.inspect} " \
      "exists=#{File.exist?(file)} raw_year=#{raw_year.inspect} year=#{year} month=#{month.inspect}"
    )

    raise ArgumentError, "file required" if raw_file.strip.empty?
    raise ArgumentError, "file not found: #{file}" unless File.exist?(file)
    raise ArgumentError, "year required (e.g. 2024)" if year <= 0
    raise ArgumentError, "month must be 1–12" if month && (month < 1 || month > 12)

    puts "[task] starting importer..."
    run = Importing::PaidOrdersWorkbookImporter.new(
      file_path: file,
      source_year: year,
      source_month: month
    ).call
    puts "[task] importer finished."

    puts(
      "import_run_id=#{run.id} " \
      "processed=#{run.processed_rows} upserted=#{run.upserted_rows} " \
      "skipped=#{run.skipped_rows} errors=#{run.error_rows}"
    )

    if run.error_rows.to_i > 0
      sample = (run.respond_to?(:error_messages) ? run.error_messages : []).first(5)
      puts "[task] sample_errors=#{sample.inspect}"
    end

    puts "[task] refreshing purchase summary cache..."
    CustomerPurchaseSummaryRefreshService.call
    puts "[task] purchase summary done."

    puts "[task] refreshing series loyalty cache..."
    CustomerSeriesLoyaltyRefreshService.call
    puts "[task] series loyalty done."

    # perform_now（非 perform_later）：import:paid_orders 是一次性 rake process，
    # process 結束後 :async 佇列裡尚未執行的 job 會遺失，所以必須在匯入完全
    # 成功（run 已 finished_at）之後、process 還活著時同步執行。刷新失敗只記
    # log、不 raise，不影響已成功寫入的訂單匯入結果。
    begin
      RefreshLivestreamStatsJob.perform_now
      puts "[task] livestream stats refresh done."
    rescue => e
      Rails.logger.warn "[import:paid_orders] livestream stats refresh failed: #{e.class} - #{e.message}"
      puts "[task] livestream stats refresh FAILED (import itself still succeeded): #{e.class} - #{e.message}"
    end
  end

  desc <<~DESC
    Delete orders that are still 已付款 in the DB for a given year/month but
    were absent from the most recently imported source file for that period
    (see Importing::CanceledOrderCandidates — printed automatically at the
    end of `import:paid_orders`).

    Always run `import:paid_orders` with the LATEST source file for that
    month first, review the candidate list it prints, and only then run this.
    This task re-derives the same candidate list itself (it does not trust
    output from a prior run), but it has no way to tell "genuinely canceled"
    apart from "the file you just imported was incomplete" — that judgment
    call is still on the human running it.

    Usage:
      DISABLE_SPRING=1 bundle exec rails "import:purge_canceled_orders[2026,8]"
  DESC
  task :purge_canceled_orders, [:year, :month] => :environment do |_t, args|
    year = args[:year].to_i
    month = args[:month].to_i

    raise ArgumentError, "year required (e.g. 2026)" if year <= 0
    raise ArgumentError, "month required, 1–12" if month < 1 || month > 12

    candidates = Importing::CanceledOrderCandidates.call(year: year, month: month).to_a

    if candidates.empty?
      puts "[purge] no canceled-order candidates found for #{year}/#{month}."
      next
    end

    puts "[purge] #{candidates.size} candidate(s) for #{year}/#{month}:"
    candidates.each do |o|
      puts "  - #{o.order_number} #{o.customer_name} #{o.product_name} #{o.checkout_amount} (#{o.order_date&.to_date})"
    end

    ids = candidates.map(&:id)
    deleted = ShoplineOrder.where(id: ids).delete_all
    puts "[purge] deleted #{deleted} row(s)."

    puts "[purge] refreshing purchase summary cache..."
    CustomerPurchaseSummaryRefreshService.call
    puts "[purge] refreshing series loyalty cache..."
    CustomerSeriesLoyaltyRefreshService.call
    puts "[purge] done."
  end
end
