# frozen_string_literal: true

module IgInbox
  # 從 CRM 回覆客人：照 Meta 的時間限制決定要不要加「真人客服」標記，送出後記成一則官方帳號的訊息、對話改成已回。
  class Reply
    class Error < StandardError; end

    def self.call(conversation, text, user:) = new(conversation, text, user).call

    def initialize(conversation, text, user)
      @conversation = conversation
      @text = text.to_s.strip
      @user = user
    end

    def call
      raise Error, "回覆內容是空的" if @text.blank?

      window = @conversation.reply_window
      raise Error, "客人最後一則訊息已超過 7 天，Meta 不允許從系統回覆，請到 IG App 回" if window == :closed

      account = Client.account(@conversation.account_key) or raise Error, "找不到 #{@conversation.account_key} 的 Meta 設定"
      body = Client.new(account).send_text(@conversation.customer_igsid, @text, human_agent: window == :human_agent)

      @conversation.ig_messages.create!(message_id: body["message_id"].presence || "crm-#{SecureRandom.uuid}",
                                        from_customer: false, text: @text, sent_at: Time.current, sent_by_user: @user)
      @conversation.refresh_state!
    rescue Client::Error => e
      raise Error, e.message
    end
  end
end
