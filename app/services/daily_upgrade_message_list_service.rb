# path: app/services/daily_upgrade_message_list_service.rb
# frozen_string_literal: true

# 每次會員報表匯入後，把「這次匯入偵測到的升級」依新卡別（白卡/銀卡/金卡/黑卡）
# 分別存成一份 MessageList 快照，讓升級名單跟既有的每日回購提醒名單一樣，
# 可以在 /message_lists/daily 直接看到、匯出、拿去發恭喜升級或引導消費的訊息。
#
# 同一個 import_run 只會呼叫一次（CustomersReportImporter 匯入完成後呼叫），
# 用 (sent_on, name) 判斷是否已建立，重跑同一天的匯入不會重複產生名單。
class DailyUpgradeMessageListService
  TARGET_LEVELS = %w[白卡 銀卡 金卡 黑卡].freeze

  def self.call(import_run)
    new.call(import_run)
  end

  def call(import_run)
    return { created: [] } unless import_run

    created = []
    TARGET_LEVELS.each do |level|
      changes = MembershipLevelChange.where(import_run: import_run, direction: "upgrade", to_level: level)
      emails = changes.filter_map { |c| c.email.presence }.uniq
      next if emails.empty?

      name = "#{Date.current.strftime('%m/%d')} 升級#{level}名單"
      next if MessageList.exists?(sent_on: Date.current, name: name)

      list = MessageListBuilder.create!(
        name: name, sent_on: Date.current, target_product: level, emails: emails,
        source_note: "由會員報表匯入（import_run##{import_run.id}）自動記錄升級為#{level}的會員",
        source: "daily_snapshot"
      )
      created << list.name
    end

    { created: created }
  end
end
