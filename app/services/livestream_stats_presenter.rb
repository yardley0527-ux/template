# frozen_string_literal: true

# 方案 B PR3：從 livestreams 的持久化統計欄位（PR2 LivestreamStatsRefreshService
# 寫入）組出畫面要用的卡別明細與未匹配差額。純函式、不查詢資料庫，
# index/show/overview 共用同一份口徑，避免各頁各自算一套。
#
# 卡別一律是「目前」membership_level（非直播當時），呼叫端 view 需標示這點。
class LivestreamStatsPresenter
  LEVELS = MembershipLevels::LEVEL_KEYS.to_a.freeze # [["黑卡","black"], ["金卡","gold"], ...]

  def self.level_rows(livestream)
    LEVELS.map do |name, key|
      { name: name, count: livestream.public_send(:"level_#{key}_count"),
        amount: livestream.public_send(:"level_#{key}_amount") }
    end
  end

  # 找不到對應 ShoplineCustomer、或卡別不在五種之列的買家，落在這裡——
  # 不算進「一般會員」（level_normal_count 已經是精確計算，不是這裡的差額）。
  def self.unmatched_buyers(livestream)
    livestream.total_buyers.to_i - level_rows(livestream).sum { |r| r[:count].to_i }
  end

  def self.unmatched_revenue(livestream)
    livestream.total_revenue.to_d - level_rows(livestream).sum { |r| r[:amount].to_d }
  end

  def self.new_buyer_pct(livestream)
    return 0.0 if livestream.total_buyers.to_i.zero?

    (livestream.new_buyers.to_f / livestream.total_buyers * 100).round(1)
  end

  def self.aov(livestream)
    return 0 if livestream.total_buyers.to_i.zero?

    (livestream.total_revenue.to_d / livestream.total_buyers).round
  end

  # 統計從未刷新過（PR1 apply 後、PR2 刷新前的狀態）。
  def self.never_refreshed?(livestream)
    livestream.stats_refreshed_at.blank?
  end

  # 場次窗口尚未走完（今天還在 D0~D+window_days 之內），數字會持續變動。
  def self.provisional?(livestream)
    Date.current <= livestream.date + livestream.window_days
  end

  def self.pct_change(current, previous)
    return nil if previous.to_f.zero?

    ((current.to_f / previous - 1) * 100).round(1)
  end
end
