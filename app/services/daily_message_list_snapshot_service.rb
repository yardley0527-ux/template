# path: app/services/daily_message_list_snapshot_service.rb
# frozen_string_literal: true

# 每天早上 ops:notifications 產生完「今日待處理」之後接著跑一次：假設當天
# 一定會照名單傳訊息，直接把當下「依產品分組」的名單存成 MessageList 快照，
# 不用等人手動點按鈕才記錄。平日才存（週六日沒有上班，不生成）；同一天同一
# 產品已經存過（例如重跑 rake）就跳過，不重複建立。
class DailyMessageListSnapshotService
  def self.call
    new.call
  end

  def call
    return { skipped: "weekend" } if Date.current.saturday? || Date.current.sunday?

    created = []
    groups, = TodayProductBoard.groups
    groups.each do |group|
      next if MessageList.exists?(sent_on: Date.current, target_product: group[:label])

      emails = NotificationProductCustomersService.call(TodayProductBoard.for_product(group[:product_key]))
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
