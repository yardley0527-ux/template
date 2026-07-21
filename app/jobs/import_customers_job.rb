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

    CustomerPurchaseSummaryRefreshService.call
    Rails.logger.info "[ImportCustomersJob] purchase summary refreshed"

    CustomerSeriesLoyaltyRefreshService.call
    Rails.logger.info "[ImportCustomersJob] series loyalty refreshed"

    # perform_now（非 perform_later）：匯入已完全成功並落地之後才呼叫，刷新
    # 失敗只記 log、不 raise，不影響已成功的顧客匯入結果（此 rescue 只包住
    # 刷新本身；匯入的成敗判定與寫入在這行之前已經完成）。
    begin
      RefreshLivestreamStatsJob.perform_now
      Rails.logger.info "[ImportCustomersJob] livestream stats refresh done (secondary trigger)"
    rescue => e
      Rails.logger.warn "[ImportCustomersJob] livestream stats refresh failed (secondary trigger): #{e.class} - #{e.message}"
    end
  rescue => e
    Rails.logger.error "[ImportCustomersJob] FAILED #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end
end