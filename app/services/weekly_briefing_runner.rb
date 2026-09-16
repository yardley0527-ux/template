# frozen_string_literal: true

# 產生每週報告前，先確保上游快取（customer_purchase_summaries／livestreams
# 統計／crm_customer_product_cycles）夠新鮮，再呼叫 WeeklyBriefingService。
#
# 2026-09-15 根因修正：原本 WeeklyBriefingsController#regenerate 完全不刷新
# crm_customer_product_cycles（只有 rake task 會刷新），導致管理員在網頁上
# 按「重新產生本週報告」時，商品回購數字是用一個月前的舊快照算出來的——
# 這是「商品回購全部為0」的真正根因（crm_customer_product_cycles 最後一次
# refreshed_at 停在 2026-08-06，之後任何一筆訂單都沒被比對過）。
#
# 這裡統一成單一進入點：rake task 跟網頁按鈕都呼叫這裡，不再各自維護一份
# 刷新邏輯，避免同一個 bug 再發生一次。預設只在偵測到「快取超過門檻時數沒更新」
# 時才重新整理（force_refresh: false），平常（cron 剛跑過)按鈕很快；
# force_refresh: true 一律強制全部重新整理，rake task 排程固定用這個。
#
# 2026-09-16：追蹤產品的回購週期重算（CrmCustomerProductCycleBuilderService）
# 改成有限並行（Concurrent::FixedThreadPool），不再逐一 product_key 序列跑。
# 這是「重新產生報告」最慢的一段——每個商品都要掃 LOOKBACK_DAYS=730 天的
# shopline_orders（目前4萬+筆）join shopline_customers，13個商品序列跑
# 實測要好幾分鐘。POOL_SIZE 刻意設得比 RAILS_MAX_THREADS（預設5、web進程與
# 背景job共用同一個DB連線池）小一截，同時處理中的執行緒各自從連線池借一條
# 連線（ActiveRecord::Base.connection_pool.with_connection），借完立刻還，
# 避免把整個進程的DB連線池佔滿、卡住其他web請求。
class WeeklyBriefingRunner
  CYCLE_STALE_HOURS      = WeeklyMetricsService::CYCLE_STALE_HOURS
  SUMMARY_STALE_HOURS    = 24
  LIVESTREAM_STALE_HOURS = 24
  CYCLE_REFRESH_POOL_SIZE = 3

  def self.call(week_start: Date.current, force_refresh: false)
    new(week_start, force_refresh).call
  end

  def initialize(week_start, force_refresh)
    @week_start = week_start
    @force_refresh = force_refresh
  end

  def call
    refresh_log = refresh_if_needed!
    briefing = WeeklyBriefingService.call(week_start: @week_start)
    [briefing, refresh_log]
  end

  private

  def refresh_if_needed!
    log = {}

    if @force_refresh || summaries_stale?
      CustomerPurchaseSummaryRefreshService.call
      log[:customer_purchase_summaries] = "refreshed"
    else
      log[:customer_purchase_summaries] = "skipped (fresh)"
    end

    if @force_refresh || livestream_stats_stale?
      LivestreamStatsRefreshService.call
      log[:livestream_stats] = "refreshed"
    else
      log[:livestream_stats] = "skipped (fresh)"
    end

    if @force_refresh || cycles_stale?
      failed = refresh_cycles_in_parallel(tracked_product_keys)
      log[:crm_customer_product_cycles] =
        if failed.empty?
          "refreshed (#{tracked_product_keys.size} products, parallel)"
        else
          "refreshed with errors (#{tracked_product_keys.size - failed.size}/#{tracked_product_keys.size} ok; failed: #{failed.join('、')})"
        end
    else
      log[:crm_customer_product_cycles] = "skipped (fresh)"
    end

    log
  end

  # 回傳處理失敗的 product_key 清單（不拋例外中斷其他商品）——一個商品的
  # SQL/資料異常不該連帶讓其他12個商品也重算失敗。
  def refresh_cycles_in_parallel(product_keys)
    return [] if product_keys.empty?

    pool = Concurrent::FixedThreadPool.new([product_keys.size, CYCLE_REFRESH_POOL_SIZE].min)
    failed = Concurrent::Array.new

    product_keys.each do |key|
      pool.post do
        ActiveRecord::Base.connection_pool.with_connection do
          CrmCustomerProductCycleBuilderService.call(product_key: key)
        end
      rescue StandardError => e
        Rails.logger.error("[WeeklyBriefingRunner] CrmCustomerProductCycleBuilderService failed product_key=#{key} #{e.class}: #{e.message}")
        failed << key
      end
    end

    pool.shutdown
    pool.wait_for_termination
    failed.to_a
  end

  def tracked_product_keys
    @tracked_product_keys ||= CrmProduct.confirmed
                                         .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
                                         .order(:id).pluck(:key)
  end

  def summaries_stale?
    latest = CustomerPurchaseSummary.maximum(:updated_at)
    latest.nil? || latest < SUMMARY_STALE_HOURS.hours.ago
  end

  def livestream_stats_stale?
    latest = Livestream.where(date: ..Date.current).maximum(:stats_refreshed_at)
    latest.nil? || latest < LIVESTREAM_STALE_HOURS.hours.ago
  end

  def cycles_stale?
    latest = CrmCustomerProductCycle.maximum(:refreshed_at)
    latest.nil? || latest < CYCLE_STALE_HOURS.hours.ago
  end
end
