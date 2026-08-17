# lib/tasks/membership_level_snapshot.rake
# frozen_string_literal: true
#
# 每日快照會員卡別人數，供 /customers/stats 的卡別成長率回推。
# Rake-only，比照 crm_rollup / ops:notifications 的模式，交給 Render Cron 排程：
#
#   bin/rails membership_level_snapshot:capture
#
# 建議排程：每天一次，晚一點跑（例如台灣時間 23:50 / UTC 15:50），
# 避免抓到當天匯入還沒跑完的中間狀態。

namespace :membership_level_snapshot do
  desc "快照今天的會員卡別人數（黑卡/金卡/銀卡/白卡/一般會員/非會員）"
  task capture: :environment do
    result = MembershipLevelSnapshotService.call
    if result[:error]
      puts "[membership_level_snapshot:capture] FAILED: #{result[:error]}"
      exit 1
    else
      snap = MembershipLevelSnapshot.find_by(snapshot_date: Date.current)
      puts "[membership_level_snapshot:capture] OK total=#{snap.total} counts=#{snap.counts}"
    end
  end
end
