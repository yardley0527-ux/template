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
  end
end
