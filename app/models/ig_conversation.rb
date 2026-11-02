# IG 私訊對話（Meta 對話 API 同步），見 ReplaceIgQuestionsWithIgInbox migration 說明。
class IgConversation < ApplicationRecord
  CATEGORIES = %w[價格／優惠活動 產品功效／適合誰 吃法／搭配 出貨／物流 訂單／付款 缺貨／到貨 合作／業配邀約 抱怨／售後 打招呼／閒聊 其他].freeze
  STATUSES = { "open" => "待處理", "ignored" => "不用回" }.freeze

  # Meta 規定：客人最後一則訊息 24 小時內可以直接回；7 天內要加「真人客服」標記；超過 7 天 API 不能回
  STANDARD_WINDOW = 24.hours
  HUMAN_AGENT_WINDOW = 7.days

  has_many :ig_messages, dependent: :delete_all

  validates :status, inclusion: { in: STATUSES.keys }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  scope :waiting, -> { where(awaiting_reply: true, status: "open") }

  # :standard / :human_agent / :closed
  def reply_window(now = Time.current)
    return :closed if last_customer_message_at.nil?

    age = now - last_customer_message_at
    return :standard if age <= STANDARD_WINDOW
    return :human_agent if age <= HUMAN_AGENT_WINDOW

    :closed
  end

  def display_name = customer_username.present? ? "@#{customer_username}" : "IG 用戶 #{customer_igsid.last(6)}"

  # 依最近的訊息重算「最後一句是不是客人講的」
  def refresh_state!
    last = ig_messages.order(:sent_at).last
    last_customer = ig_messages.where(from_customer: true).maximum(:sent_at)
    attrs = { last_message_at: last&.sent_at, awaiting_reply: last&.from_customer || false,
              last_customer_message_at: last_customer }
    # 客人又傳新訊息時，之前按「不用回」的要重新打開
    attrs[:status] = "open" if status == "ignored" && last_customer && last_customer > (last_customer_message_at || last_customer)
    update!(attrs)
  end
end
