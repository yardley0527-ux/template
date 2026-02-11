# path: lib/tasks/import_paid_orders.rake
# frozen_string_literal: true

namespace :import do
  desc <<~DESC
    Import paid orders workbook (.xlsx).

    Usage:
      DISABLE_SPRING=1 bundle exec rails "import:paid_orders[/path/file.xlsx,2024]"

    Example:
      DISABLE_SPRING=1 bundle exec rails "import:paid_orders[/Users/serenachang/Downloads/2024已付款訂單.xlsx,2024]"
  DESC
  task :paid_orders, [:file, :year] => :environment do |_t, args|
    raw_file = args[:file].to_s
    raw_year = args[:year].to_s

    file = File.expand_path(raw_file)
    year = raw_year.to_i

    puts(
      "[task] raw_file=#{raw_file.inspect} expanded_file=#{file.inspect} " \
      "exists=#{File.exist?(file)} raw_year=#{raw_year.inspect} year=#{year}"
    )

    raise ArgumentError, "file required" if raw_file.strip.empty?
    raise ArgumentError, "file not found: #{file}" unless File.exist?(file)
    raise ArgumentError, "year required (e.g. 2024)" if year <= 0

    puts "[task] starting importer..."
    run = Importing::PaidOrdersWorkbookImporter.new(file_path: file, source_year: year).call
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
  end
end
