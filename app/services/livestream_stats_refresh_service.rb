# frozen_string_literal: true

require "zlib"

# 方案 B PR2：把 LivestreamAttribution 的計算值寫入 livestreams 的統計快取欄位
# （total_orders/total_revenue/total_buyers/new_buyers/level_*_count/level_*_amount/
# stats_refreshed_at）。這是唯一會寫入這些欄位的地方。
#
# - 每場獨立 transaction：單場失敗不影響其他場次
# - 冪等：重跑會覆蓋為最新計算值，不累加
# - session 級 **blocking** PostgreSQL advisory lock：整個 run（含所有場次的
#   per-event transaction）鎖在同一個從 connection pool 明確 checkout 的連線上，
#   確保鎖與後續查詢屬於同一個 Postgres session。第二個刷新呼叫會等待第一個
#   完成並釋放鎖後，才開始「重新完整計算」——不是略過本次、也不是接續舊結果。
#   人工一次性操作（LivestreamBackfill#apply）用的是非阻塞 try lock＋abort，
#   因為那是操作者手動觸發、要能立即知道衝突；這裡是背景刷新，等待是正確行為。
# - SyncRun(source="livestream_stats") 記錄 success/partial/failed。
#   error_messages 只存「日期＋例外類別＋固定安全摘要」，絕不寫入原始
#   exception.message（可能含 email/電話/姓名等個資或 SQL bind 值）。
#   完整例外（含 message 與 backtrace）只送 Rails.logger.error（本專案既有的
#   受控 server log 出口，與 ImportCustomersJob 的錯誤處理慣例一致）。
class LivestreamStatsRefreshService
  SYNC_SOURCE = "livestream_stats"
  LOCK_KEY = "livestream_stats_refresh"
  LOCK_ID = Zlib.crc32(LOCK_KEY)
  SAFE_ERROR_SUFFIX = "統計刷新失敗，詳情見 server log"

  def self.call(date: nil)
    new(date: date).call
  end

  def initialize(date: nil)
    @date = date
  end

  # 回傳建立的 SyncRun。鎖忙碌時會阻塞等待，不會略過本次刷新。
  def call
    ActiveRecord::Base.connection_pool.with_connection do |conn|
      conn.execute("SELECT pg_advisory_lock(#{LOCK_ID})")
      begin
        run_refresh
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{LOCK_ID})")
      end
    end
  end

  private

  def run_refresh
    run = SyncRun.create!(source: SYNC_SOURCE, status: "running", started_at: Time.current, meta: {})

    succeeded = []
    failed = []
    scope.find_each do |livestream|
      refresh_one!(livestream)
      succeeded << livestream.date.iso8601
    rescue => e
      log_full_exception(livestream, e)
      failed << { date: livestream.date.iso8601, exception_class: e.class.to_s }
    end

    status = if failed.empty?
               "success"
             elsif succeeded.any?
               "partial"
             else
               "failed"
             end

    run.update!(
      status: status,
      finished_at: Time.current,
      meta: { "attempted" => succeeded.size + failed.size, "succeeded" => succeeded.size, "failed" => failed.size },
      error_messages: failed.map { |f| "#{f[:date]}: #{f[:exception_class]} — #{SAFE_ERROR_SUFFIX}" }
    )
    run
  end

  def scope
    @date ? Livestream.where(date: @date) : Livestream.all
  end

  def refresh_one!(livestream)
    ActiveRecord::Base.transaction do
      attribution = LivestreamAttribution.new(livestream)
      levels = level_breakdown(attribution)

      livestream.update!(
        total_orders: attribution.orders,
        total_revenue: attribution.revenue,
        total_buyers: attribution.buyers,
        new_buyers: attribution.new_buyers,
        stats_refreshed_at: Time.current,
        **levels
      )
    end
  end

  # 卡別統計使用「目前」membership_level，非直播當下的歷史卡別（ShoplineCustomer
  # 不記錄卡別異動時間點，與既有 MembershipLevelStatsService 的既定限制一致；
  # UI 顯示時需標示「現值卡別」）。
  #
  # 找不到對應 ShoplineCustomer、或卡別不在 MembershipLevels::TARGET_MEMBERSHIPS
  # 五種之列的買家，不會被計入任何 level_* 欄位（不會被誤算進「一般會員」）。
  def level_breakdown(attribution)
    emails = attribution.order_rows.filter_map { |r| r[:email] }.uniq
    return empty_level_breakdown if emails.empty?

    # 每個 email 只出現一次（來自已去重的 order_rows），故 count 不會因同一
    # email 多張訂單而放大；amount 加總該 email 全部去重後訂單的金額。
    amounts_by_email = Hash.new(0)
    attribution.order_rows.each { |r| amounts_by_email[r[:email]] += r[:amount] if r[:email].present? }

    # 若同一 email 存在多筆 ShoplineCustomer 紀錄（資料重複），.order(:id) 讓
    # 最新一筆決定卡別；不論哪筆勝出，emails 本身已是唯一集合，Hash 查找不會
    # 讓同一買家的人數或金額被重複計入兩次。
    membership_by_email = ShoplineCustomer.where(email: emails).order(:id).pluck(:email, :membership_level).to_h

    MembershipLevels::LEVEL_KEYS.each_with_object({}) do |(level_name, key), result|
      level_emails = emails.select { |e| membership_by_email[e] == level_name }
      result[:"level_#{key}_count"] = level_emails.size
      result[:"level_#{key}_amount"] = level_emails.sum { |e| amounts_by_email[e] }
    end
  end

  def empty_level_breakdown
    MembershipLevels::LEVEL_KEYS.each_with_object({}) do |(_name, key), result|
      result[:"level_#{key}_count"] = 0
      result[:"level_#{key}_amount"] = 0
    end
  end

  # 完整例外只進 Rails.logger（受控 server log）。額外套一層 Rails 既有的
  # ActiveSupport::ParameterFilter（config.filter_parameters 同一套機制）—
  # 誠實註記：ParameterFilter 是依 Hash 的「鍵名」比對過濾，不會逐字掃描/遮蔽
  # e.message 這種自由文字內容裡「剛好」出現的 email／電話字串；真正的防線是
  # SyncRun.error_messages 從不寫入 e.message（見上方安全摘要），這裡的過濾
  # 只是對結構化欄位（date/exception class）的額外一層、非唯一防線。
  def log_full_exception(livestream, exception)
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(date: livestream.date.iso8601, exception_class: exception.class.to_s)
    Rails.logger.error(
      "[LivestreamStatsRefreshService] #{filtered.inspect} message=#{exception.message} " \
      "backtrace=#{exception.backtrace&.first(5)&.join(' | ')}"
    )
  end
end
