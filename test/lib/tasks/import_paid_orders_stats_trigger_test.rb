# frozen_string_literal: true

require "test_helper"
require "rake"

# 訂單匯入後觸發統計刷新的行為測試（PR2 修正版：改用 perform_now 同步執行，
# 不再是 perform_later 排入 :async 佇列——一次性 rake process 結束後 :async
# 記憶體佇列裡尚未執行的 job 會遺失，所以改用同步呼叫並用「真的跑完、
# 產生新的 SyncRun」來驗證，而不是「有沒有被排入佇列」）。
#
# 用近乎空的 CSV（只有表頭、零資料列）跑真正的 import:paid_orders task，
# 避免依賴完整商品/客戶對應邏輯——重點是驗證「匯入成功後刷新真的同步執行了」。
class ImportPaidOrdersStatsTriggerTest < ActiveSupport::TestCase
  setup do
    unless $rake_tasks_loaded_for_tests
      Rails.application.load_tasks
      $rake_tasks_loaded_for_tests = true
    end
    Rake::Task["import:paid_orders"].reenable
  end

  def csv_path
    Rails.root.join("tmp", "paid_orders_trigger_test_#{SecureRandom.hex(4)}.csv")
  end

  test "successful paid orders import synchronously runs the stats refresh (creates a new SyncRun)" do
    path = csv_path
    File.write(path, "訂單號碼\n")

    begin
      assert_difference "SyncRun.where(source: 'livestream_stats').count", 1 do
        silence_stream_output { Rake::Task["import:paid_orders"].invoke(path.to_s, "2030", "1") }
      end
      run = SyncRun.where(source: "livestream_stats").order(:created_at).last
      assert_equal "success", run.status
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  test "import failure aborts before the trigger runs (no stats refresh SyncRun created)" do
    assert_no_difference "SyncRun.where(source: 'livestream_stats').count" do
      assert_raises(ArgumentError) do
        silence_stream_output { Rake::Task["import:paid_orders"].invoke("/no/such/file.csv", "2030", "1") }
      end
    end
  end

  test "a stats refresh failure does not undo the already-committed import" do
    path = csv_path
    File.write(path, "訂單號碼\n")

    # LivestreamStatsRefreshService.call 是自定義類別方法（非繼承而來），
    # remove_method 後沒有祖先可回退、會讓後續所有呼叫永久壞掉——必須先存下
    # 原始 Method 物件，事後用它復原，不能用 remove_method。
    original_call = LivestreamStatsRefreshService.method(:call)
    LivestreamStatsRefreshService.define_singleton_method(:call) { |**_kwargs| raise "boom" }
    begin
      import_run_count_before = ImportRun.where(kind: "paid_orders_workbook").count
      # rake task 內對刷新的 rescue 吞掉例外，不會讓整個 task 失敗
      silence_stream_output { Rake::Task["import:paid_orders"].invoke(path.to_s, "2030", "1") }
      assert_equal import_run_count_before + 1, ImportRun.where(kind: "paid_orders_workbook").count
    ensure
      LivestreamStatsRefreshService.define_singleton_method(:call, original_call)
      File.delete(path) if File.exist?(path)
    end
  end

  private

  def silence_stream_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end
end
