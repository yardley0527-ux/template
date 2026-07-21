# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/crm_rollup_runner")

class CrmRollupRunnerTest < ActiveSupport::TestCase
  # minitest 6 已移除 minitest/mock，這裡自備最小 singleton-method stub。
  def with_stub(klass, method_name, impl)
    original = klass.method(method_name)
    klass.singleton_class.send(:remove_method, method_name)
    klass.define_singleton_method(method_name) do |*args, **kwargs|
      impl.respond_to?(:call) ? impl.call(*args, **kwargs) : impl
    end
    yield
  ensure
    klass.singleton_class.send(:remove_method, method_name)
    klass.define_singleton_method(method_name, original)
  end

  # run_all 的 exit(1) 會讓測試 process 中斷，改以攔截 SystemExit 驗證。
  def run_all_capturing_exit(runner)
    capture_io { runner.run_all }
    nil
  rescue SystemExit => e
    e.status
  end

  def runner
    CrmRollupRunner.new(stat_date: Date.new(2026, 7, 21), stat_month: Date.new(2026, 7, 1))
  end

  def stub_services(tracking:, daily: 1, monthly: 1, &block)
    with_stub(CrmCustomerProductTrackingRefreshService, :call, tracking) do
      with_stub(CrmProductDailyStatsRefreshService, :call, daily) do
        with_stub(CrmProductMonthlyStatsRefreshService, :call, monthly, &block)
      end
    end
  end

  test "run_all records a success sync_run with per-product meta" do
    stub_services(tracking: 42) do
      assert_nil run_all_capturing_exit(runner)
    end

    run = SyncRun.latest_for("crm_rollup")
    assert_equal "success", run.status
    assert run.finished_at.present?
    assert_equal JourneyProducts::PRODUCTS.keys.sort, run.meta.keys.sort

    entry = run.meta["omnipotent"]
    assert_equal 42, entry["tracking_rows"]
    assert_nil entry["error"]
    assert entry["seconds"].is_a?(Numeric)
  end

  test "one product failing marks partial, records error class only, and continues others" do
    calls = []
    failing = lambda do |product_key:|
      calls << product_key
      raise ArgumentError, "boom with customer@example.com inside" if product_key == "metabolism"

      7
    end

    with_stub(CrmCustomerProductTrackingRefreshService, :call, failing) do
      with_stub(CrmProductDailyStatsRefreshService, :call, ->(**) { 1 }) do
        with_stub(CrmProductMonthlyStatsRefreshService, :call, ->(**) { 1 }) do
          assert_equal 1, run_all_capturing_exit(runner)
        end
      end
    end

    # per-product rescue：失敗的產品不會中斷其他產品
    assert_equal JourneyProducts::PRODUCTS.keys.sort, calls.sort

    run = SyncRun.latest_for("crm_rollup")
    assert_equal "partial", run.status
    assert_equal "ArgumentError", run.meta["metabolism"]["error"]
    # 錯誤訊息（可能含個資）不得入庫，只存 class 名
    assert_no_match(/customer@example\.com/, run.meta.to_json)
    assert_nil run.meta["omnipotent"]["error"]
    # current_alerts 能點名失敗產品
    assert_includes SyncRun.current_alerts.join, "metabolism"
  end

  test "all products failing marks failed" do
    with_stub(CrmCustomerProductTrackingRefreshService, :call, ->(**) { raise "x" }) do
      assert_equal 1, run_all_capturing_exit(runner)
    end

    assert_equal "failed", SyncRun.latest_for("crm_rollup").status
  end

  test "lock-busy skip is recorded as skipped, not an error" do
    stub_services(tracking: :skipped) do
      assert_nil run_all_capturing_exit(runner)
    end

    run = SyncRun.latest_for("crm_rollup")
    assert_equal "success", run.status
    assert run.meta["omnipotent"]["skipped"]
    assert_nil run.meta["omnipotent"]["error"]
  end
end
