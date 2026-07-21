# frozen_string_literal: true

# CrmRollupRunner — 僅供 crm_rollup rake task 使用（明確 require，不進 autoload 路徑）。
#
# run_all 會建立一筆 SyncRun(source: "crm_rollup")，讓 rollup 的成敗與新鮮度
# 出現在首頁 sync_alerts 上（cron 靜默失敗過去只能靠 refreshed_at 倒推）。
# meta 只記錄統計數字與例外類別名稱——錯誤訊息可能內含 SQL 片段（email、
# 訂單內容），一律不入庫，完整訊息只進 stdout/log。
class CrmRollupRunner
  def self.parse_stat_date
    parse_date(ENV["STAT_DATE"], "STAT_DATE") { Date.current }
  end

  def self.parse_stat_month
    parse_date(ENV["STAT_MONTH"], "STAT_MONTH") { Date.current.beginning_of_month }.beginning_of_month
  end

  def self.parse_date(raw, env_name)
    return yield if raw.blank?

    Date.strptime(raw, "%Y-%m-%d")
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{env_name} must be in YYYY-MM-DD format, got: #{raw.inspect}"
  end

  def initialize(stat_date:, stat_month:)
    @stat_date  = stat_date
    @stat_month = stat_month
  end

  def run_product(product_key)
    tracking_rows = run_step(product_key, "tracking") do
      CrmCustomerProductTrackingRefreshService.call(product_key: product_key)
    end

    run_step(product_key, "daily") do
      CrmProductDailyStatsRefreshService.call(product_key: product_key, stat_date: @stat_date)
    end

    run_step(product_key, "monthly") do
      CrmProductMonthlyStatsRefreshService.call(product_key: product_key, stat_month: @stat_month)
    end

    tracking_rows
  end

  def run_all
    sync_run = create_sync_run
    product_keys = JourneyProducts::PRODUCTS.keys
    meta = {}
    failed = []

    product_keys.each do |product_key|
      product_started_at = Time.current
      begin
        tracking_rows = run_product(product_key)
        meta[product_key] = {
          "tracking_rows" => tracking_rows.is_a?(Integer) ? tracking_rows : nil,
          "skipped"       => tracking_rows == :skipped,
          "seconds"       => elapsed_since(product_started_at),
          "error"         => nil
        }
      rescue StandardError => e
        failed << product_key
        meta[product_key] = {
          "tracking_rows" => nil,
          "skipped"       => false,
          "seconds"       => elapsed_since(product_started_at),
          "error"         => e.class.name
        }
      end
    end

    finish_sync_run(sync_run,
      status: overall_status(total: product_keys.size, failed: failed.size),
      meta:   meta)

    ok = product_keys.size - failed.size
    puts "[crm_rollup] SUMMARY total=#{product_keys.size} ok=#{ok} failed=#{failed.size} failed_products=#{failed.join(',')}"

    exit(1) if failed.any?
  rescue StandardError => e
    # runner 本身掛掉（非單一產品失敗）：SyncRun 若已建立要收尾成 failed。
    finish_sync_run(sync_run, status: "failed", meta: { "runner_error" => e.class.name }) if sync_run
    raise
  end

  private

  def create_sync_run
    SyncRun.create!(source: "crm_rollup", status: "running", started_at: Time.current)
  rescue StandardError => e
    # 觀測層失效不應阻止 rollup 本體執行。
    puts "[crm_rollup] sync_run create failed: #{e.class.name}"
    nil
  end

  def finish_sync_run(sync_run, status:, meta:)
    return unless sync_run

    sync_run.update!(status: status, finished_at: Time.current, meta: meta)
  rescue StandardError => e
    puts "[crm_rollup] sync_run finish failed: #{e.class.name}"
  end

  def overall_status(total:, failed:)
    return "failed"  if failed == total
    return "partial" if failed.positive?

    "success"
  end

  def elapsed_since(started_at)
    (Time.current - started_at).round(2)
  end

  # Logs status=ok / status=skipped / status=error for one step, then
  # re-raises on error so run_product stops the remaining steps for this
  # product (daily must not run against a tracking refresh that failed).
  def run_step(product_key, step)
    result = yield
    if result == :skipped
      puts "[crm_rollup] product=#{product_key} step=#{step} status=skipped reason=lock_busy"
    else
      puts "[crm_rollup] product=#{product_key} step=#{step} status=ok result=#{result.inspect}"
    end
    result
  rescue StandardError => e
    puts "[crm_rollup] product=#{product_key} step=#{step} status=error message=#{e.message.inspect}"
    raise
  end
end
