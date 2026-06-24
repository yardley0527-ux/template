# lib/tasks/crm_rollup.rake
# frozen_string_literal: true
#
# Rollup Phase 2D — unified CLI entry point that runs the 3 existing rollup
# services (tracking -> daily stats -> monthly stats) in sequence, either for
# one product or for every product in JourneyProducts::PRODUCTS.
#
# Rake-only by design: GoodJob / queue backend is still ON HOLD, and a rake
# task can be invoked directly from a system cron or hosting-platform
# scheduler without depending on that decision.

namespace :crm_rollup do
  desc <<~DESC
    Refresh tracking -> daily stats -> monthly stats for one product, in order.
    Any step failing aborts this product's remaining steps and raises (exit code != 0).

    Usage:
      bin/rails "crm_rollup:refresh[omnipotent]"
      STAT_DATE=2026-06-20 STAT_MONTH=2026-06-01 bin/rails "crm_rollup:refresh[omnipotent]"
  DESC
  task :refresh, [:product_key] => :environment do |_t, args|
    runner = CrmRollupRunner.new(
      stat_date:  CrmRollupRunner.parse_stat_date,
      stat_month: CrmRollupRunner.parse_stat_month
    )
    runner.run_product(args[:product_key])
  end

  desc <<~DESC
    Refresh tracking -> daily stats -> monthly stats for every product in
    JourneyProducts::PRODUCTS. One product failing does not stop the others,
    but the task exits non-zero if any product failed.

    Usage:
      bin/rails crm_rollup:refresh_all
      STAT_DATE=2026-06-20 STAT_MONTH=2026-06-01 bin/rails crm_rollup:refresh_all
  DESC
  task refresh_all: :environment do
    runner = CrmRollupRunner.new(
      stat_date:  CrmRollupRunner.parse_stat_date,
      stat_month: CrmRollupRunner.parse_stat_month
    )
    runner.run_all
  end
end

# ─────────────────────────────────────────────────────────────────────
# CrmRollupRunner — 僅供 crm_rollup rake task 使用，不進 autoload 路徑
# ─────────────────────────────────────────────────────────────────────
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
    run_step(product_key, "tracking") do
      CrmCustomerProductTrackingRefreshService.call(product_key: product_key)
    end

    run_step(product_key, "daily") do
      CrmProductDailyStatsRefreshService.call(product_key: product_key, stat_date: @stat_date)
    end

    run_step(product_key, "monthly") do
      CrmProductMonthlyStatsRefreshService.call(product_key: product_key, stat_month: @stat_month)
    end
  end

  def run_all
    product_keys = JourneyProducts::PRODUCTS.keys
    failed = []

    product_keys.each do |product_key|
      begin
        run_product(product_key)
      rescue StandardError
        failed << product_key
      end
    end

    ok = product_keys.size - failed.size
    puts "[crm_rollup] SUMMARY total=#{product_keys.size} ok=#{ok} failed=#{failed.size} failed_products=#{failed.join(',')}"

    exit(1) if failed.any?
  end

  private

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
