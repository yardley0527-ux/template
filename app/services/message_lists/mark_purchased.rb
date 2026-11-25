# frozen_string_literal: true

module MessageLists
  # 跑訂單簡報時一起跑：把某天已付款、買了名單目標商品的客人，
  # 在「還沒傳出去」的人工名單上記「已買」日期（purchased_on），避免剛買完又收到推銷訊息。
  #
  # 只看傳送日在這天之後的名單——傳送日當天或之後買的，show 頁本來就會算成「已回購」。
  # 已經有日期的不覆蓋（保留最早買的那天）。
  class MarkPurchased
    def self.call(date)
      new(date).call
    end

    def initialize(date)
      @date = date.to_date
    end

    # 回傳 [{ list: MessageList, recipients: [MessageListRecipient...] }]，只列有更新的名單
    def call
      MessageList.manual.where("sent_on > ?", @date).order(:sent_on, :id).filter_map do |list|
        emails = buyer_emails(list.target_product)
        next if emails.empty?

        recipients = list.recipients.where(email: emails, purchased_on: nil).to_a
        next if recipients.empty?

        MessageListRecipient.where(id: recipients.map(&:id)).update_all(purchased_on: @date, updated_at: Time.current)
        { list: list, recipients: recipients }
      end
    end

    private

    # 目標商品可用「、」或「,」分隔多個關鍵字，符合任一個即算（同 MessageListsController#repurchases_for）
    def buyer_emails(target_product)
      keywords = target_product.to_s.split(/[、,]/).filter_map { |k| k.strip.presence }
      return [] if keywords.empty?

      scope = ShoplineOrder.where(payment_status: "已付款").where("order_date::date = ?", @date)
      match = keywords.map { |k| ShoplineOrder.sanitize_sql_array(["product_name ILIKE ?", "%#{ShoplineOrder.sanitize_sql_like(k)}%"]) }.join(" OR ")
      scope.where(match).where.not(email: [nil, ""]).distinct.pluck(Arel.sql("LOWER(TRIM(email))"))
    end
  end
end
