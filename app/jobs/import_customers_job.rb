# path: app/jobs/import_customers_job.rb

class ImportCustomersJob < ApplicationJob
  queue_as :default

  def perform(file_path, sheet: 0, header_row: 1)
    Rails.logger.info "[ImportCustomersJob] starting file=#{file_path}"

    run = Importing::CustomersReportImporter.new(
      file_path: file_path,
      sheet: sheet,
      header_row: header_row,
      verbose: false
    ).call

    Rails.logger.info "[ImportCustomersJob] done run_id=#{run.id} processed=#{run.processed_rows} upserted=#{run.upserted_rows} errors=#{run.error_rows}"
  rescue => e
    Rails.logger.error "[ImportCustomersJob] FAILED #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end
end