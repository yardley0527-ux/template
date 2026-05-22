# path: lib/tasks/import_customers_report.rake
# frozen_string_literal: true

namespace :import do
  desc 'Import Shopline customers report (.xls). Usage: rails "import:customers_report[/path/file.xls]"'
  task :customers_report, [:file] => :environment do |_t, args|
    raw_file = args[:file].to_s
    file = File.expand_path(raw_file)

    puts "[task] raw_file=#{raw_file.inspect} expanded_file=#{file.inspect} exists=#{File.exist?(file)}"
    raise ArgumentError, "file required" if raw_file.strip.empty?
    raise ArgumentError, "file not found: #{file}" unless File.exist?(file)

    puts "[task] starting importer..."
    run = Importing::CustomersReportImporter.new(file_path: file).call
    puts "[task] importer finished."

    puts(
      "import_run_id=#{run.id} processed=#{run.processed_rows} " \
      "upserted=#{run.upserted_rows} skipped=#{run.skipped_rows} errors=#{run.error_rows}"
    )
    puts "[task] sample_errors=#{run.error_messages.first(5).inspect}" if run.error_rows.to_i > 0

    puts "[task] refreshing purchase summary cache..."
    CustomerPurchaseSummaryRefreshService.call
    puts "[task] cache refresh done."
  end
end
