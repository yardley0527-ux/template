# frozen_string_literal: true

# 每天存一筆會員卡別（黑卡/金卡/銀卡/白卡/一般會員/非會員）人數快照，
# 讓 /customers/stats 之後可以回答「卡別成長率」「今年 vs 去年」這類問題
# （目前 membership_level 欄位只存最新狀態，沒有累積快照就永遠無法回推）。
class MembershipLevelSnapshotService
  def self.call
    new.call
  end

  def call
    run = SyncRun.create!(source: "membership_level_snapshot", started_at: Time.current)

    counts = ShoplineCustomer.group(:membership_level).count
                              .each_with_object(Hash.new(0)) { |(level, n), h| h[level.presence || "非會員"] += n }
    total = counts.values.sum

    MembershipLevelSnapshot
      .find_or_initialize_by(snapshot_date: Date.current)
      .update!(counts: counts, total: total)

    run.update!(status: "success", finished_at: Time.current, meta: counts.merge("total" => total))
    { error: nil }
  rescue StandardError => e
    Rails.logger.error("[MembershipLevelSnapshotService] #{e.class} #{e.message}")
    run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
    { error: "#{e.class}: #{e.message}" }
  end
end
