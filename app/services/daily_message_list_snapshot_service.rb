# path: app/services/daily_message_list_snapshot_service.rb
# frozen_string_literal: true

# 把當下「依產品分組」的今日待處理名單存成 MessageList 快照，不用等人手動點
# 按鈕才記錄。平日才存（週六日沒有上班，不生成）；同一天同一產品已經存過就
# 跳過，不重複建立——這個 idempotent 特性讓這支 service 可以被叫很多次也沒事。
#
# 兩個觸發點都會呼叫：
#   1. ops:notifications rake（每天早上）—— 保底，就算沒人開營運提醒中心也會記到。
#   2. NotificationBoardController#index 的「今日待處理」分頁每次載入——因為
#      「今日待處理」是即時查詢，一天內可能持續有新產品冒出來（例如延後的提醒
#      到時間醒來），只靠早上那一次 rake 會漏掉當天稍後才出現的產品。兩邊都呼叫
#      同一支 service，才能保證快照涵蓋的產品跟畫面上「今日待處理」看到的一致。
class DailyMessageListSnapshotService
  def self.call(woken_ids: [])
    new.call(woken_ids: woken_ids)
  end

  def call(woken_ids: [])
    return { skipped: "weekend" } if Date.current.saturday? || Date.current.sunday?

    created = []
    groups, = TodayProductBoard.groups(woken_ids: woken_ids)
    groups.each do |group|
      next if MessageList.exists?(sent_on: Date.current, target_product: group[:label])

      emails = NotificationProductCustomersService.call(TodayProductBoard.for_product(group[:product_key], woken_ids: woken_ids))
                 .filter_map { |r| r[:email].presence }
      next if emails.empty?

      list = MessageListBuilder.create!(
        name: "#{Date.current.strftime('%m/%d')} #{group[:label]}回購名單",
        sent_on: Date.current, target_product: group[:label], emails: emails,
        source_note: "由營運提醒中心「今日待處理・#{group[:label]}」自動記錄", source: "daily_snapshot"
      )
      created << list.name
    end

    { created: created }
  end
end
