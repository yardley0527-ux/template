# path: app/jobs/import_paid_orders_job.rb

class ImportPaidOrdersJob < ApplicationJob
  queue_as :default

  def perform(file_path, source_year:, source_month: nil)
    Rails.logger.info "[ImportPaidOrdersJob] starting file=#{file_path} year=#{source_year} month=#{source_month.inspect}"

    run = Importing::PaidOrdersWorkbookImporter.new(
      file_path: file_path,
      source_year: source_year,
      source_month: source_month,
      verbose: false
    ).call

    Rails.logger.info "[ImportPaidOrdersJob] done run_id=#{run.id} processed=#{run.processed_rows} upserted=#{run.upserted_rows} errors=#{run.error_rows}"

    CustomerPurchaseSummaryRefreshService.call
    Rails.logger.info "[ImportPaidOrdersJob] purchase summary refreshed"

    CustomerSeriesLoyaltyRefreshService.call
    Rails.logger.info "[ImportPaidOrdersJob] series loyalty refreshed"

    # perform_now（非 perform_later）：匯入已完全成功並落地之後才呼叫，刷新
    # 失敗只記 log、不 raise，不影響已成功寫入的訂單匯入結果（同
    # lib/tasks/import_paid_orders.rake 與 ImportCustomersJob 的作法）。
    begin
      RefreshLivestreamStatsJob.perform_now
      Rails.logger.info "[ImportPaidOrdersJob] livestream stats refresh done (secondary trigger)"
    rescue => e
      Rails.logger.warn "[ImportPaidOrdersJob] livestream stats refresh failed (secondary trigger): #{e.class} - #{e.message}"
    end
  rescue => e
    Rails.logger.error "[ImportPaidOrdersJob] FAILED #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end
end
