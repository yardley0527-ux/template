# frozen_string_literal: true

require "test_helper"

# PR2 修正版：ImportCustomersJob 的次要觸發改用 perform_now（見
# app/jobs/import_customers_job.rb 的說明），不再是 perform_later 排入
# :async 佇列，因此這裡改用「是否真的同步跑完（新增一筆 livestream_stats
# SyncRun）」驗證，而不是斷言 job 有沒有被 enqueue。
class ImportCustomersJobTest < ActiveSupport::TestCase
  FakeRun = Struct.new(:id, :processed_rows, :upserted_rows, :error_rows)

  def with_stubbed_importer(fake_call_result:, &block)
    original_new = Importing::CustomersReportImporter.method(:new)
    Importing::CustomersReportImporter.define_singleton_method(:new) do |**_kwargs|
      Class.new { define_method(:call) { fake_call_result } }.new
    end
    original_purchase = CustomerPurchaseSummaryRefreshService.method(:call)
    CustomerPurchaseSummaryRefreshService.define_singleton_method(:call) { nil }
    original_loyalty = CustomerSeriesLoyaltyRefreshService.method(:call)
    CustomerSeriesLoyaltyRefreshService.define_singleton_method(:call) { nil }

    block.call
  ensure
    Importing::CustomersReportImporter.define_singleton_method(:new, original_new)
    CustomerPurchaseSummaryRefreshService.define_singleton_method(:call, original_purchase)
    CustomerSeriesLoyaltyRefreshService.define_singleton_method(:call, original_loyalty)
  end

  test "successful customers import synchronously runs livestream stats refresh (secondary trigger)" do
    fake_run = FakeRun.new(1, 0, 0, 0)
    with_stubbed_importer(fake_call_result: fake_run) do
      assert_difference "SyncRun.where(source: 'livestream_stats').count", 1 do
        ImportCustomersJob.new.perform("fake/path.xlsx")
      end
    end
    run = SyncRun.where(source: "livestream_stats").order(:created_at).last
    assert_equal "success", run.status
  end

  test "failed customers import does not trigger livestream stats refresh" do
    original_new = Importing::CustomersReportImporter.method(:new)
    Importing::CustomersReportImporter.define_singleton_method(:new) { |**_kwargs| raise "boom" }

    begin
      assert_no_difference "SyncRun.where(source: 'livestream_stats').count" do
        assert_raises(RuntimeError) { ImportCustomersJob.new.perform("fake/path.xlsx") }
      end
    ensure
      Importing::CustomersReportImporter.define_singleton_method(:new, original_new)
    end
  end

  test "a stats refresh failure does not change the outcome of an otherwise-successful import" do
    fake_run = FakeRun.new(1, 0, 0, 0)
    with_stubbed_importer(fake_call_result: fake_run) do
      # LivestreamStatsRefreshService.call 是自定義類別方法（非繼承而來），
      # remove_method 後沒有祖先可回退、會讓後續所有呼叫永久壞掉——必須先存下
      # 原始 Method 物件，事後用它復原，不能用 remove_method。
      original_call = LivestreamStatsRefreshService.method(:call)
      LivestreamStatsRefreshService.define_singleton_method(:call) { |**_kwargs| raise "boom" }
      begin
        # rescue 吞掉刷新失敗，perform 正常結束、不 raise（匯入本身視為成功）
        assert_nothing_raised { ImportCustomersJob.new.perform("fake/path.xlsx") }
      ensure
        LivestreamStatsRefreshService.define_singleton_method(:call, original_call)
      end
    end
  end
end
