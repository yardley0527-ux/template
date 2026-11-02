# frozen_string_literal: true

module IgInbox
  # 把 IG 最近有動靜的對話抓進 ig_conversations / ig_messages，重算「最後一句是不是客人講的」。
  # 第一次抓 14 天；之後從上次同步前 1 小時開始抓（重疊一點，避免漏掉）。
  # ManyChat 自動回覆也是從官方帳號送出，所以被 ManyChat 回過的對話算「已回」。
  class Sync
    FIRST_LOOKBACK = 14.days

    def self.call = new.call

    def call
      result = { conversations: 0, messages: 0, errors: [] }
      Client.accounts.each do |account|
        since = (IgConversation.where(account_key: account.key).maximum(:last_message_at) || FIRST_LOOKBACK.ago) - 1.hour
        Client.new(account).conversations(since: since).each do |c|
          result[:messages] += save_conversation(account, c)
          result[:conversations] += 1
        end
      rescue Client::Error => e
        result[:errors] << "#{account.key}: #{e.message}"
      end
      result
    end

    private

    def save_conversation(account, c)
      own_ids = [account.ig_user_id, account.page_id].compact_blank
      customer = Array(c.dig("participants", "data")).find do |p|
        !own_ids.include?(p["id"].to_s) && p["username"].to_s.downcase != account.key
      end
      return 0 unless customer

      conversation = IgConversation.find_or_initialize_by(account_key: account.key, conversation_id: c["id"])
      conversation.update!(customer_igsid: customer["id"].to_s, customer_username: customer["username"].presence || conversation.customer_username)

      now = Time.current
      rows = Array(c.dig("messages", "data")).map do |m|
        { ig_conversation_id: conversation.id, message_id: m["id"],
          from_customer: m.dig("from", "id").to_s == customer["id"].to_s,
          text: m["message"].presence || "（圖片、貼圖或分享貼文）",
          sent_at: Time.zone.parse(m["created_time"].to_s), created_at: now, updated_at: now }
      end
      return 0 if rows.empty?

      before = conversation.ig_messages.count
      IgMessage.insert_all(rows, unique_by: :message_id)
      conversation.refresh_state!
      conversation.ig_messages.count - before
    end
  end
end
