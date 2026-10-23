# frozen_string_literal: true

class LineBotGroup < ApplicationRecord
  # 群組可以訂閱的報告；新加入的群組預設什麼都不收，要到 /line_bot_groups 勾選
  TOPICS = {
    "seo_daily" => "SEO 日報（平日 10:00）",
    "order_brief" => "訂單簡報（匯入前一天訂單後）"
  }.freeze

  validates :group_id, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
  scope :subscribed_to, ->(topic) { active.where("? = ANY(subscriptions)", topic) }

  before_validation { self.subscriptions = Array(subscriptions).compact_blank.uniq & TOPICS.keys }
end
