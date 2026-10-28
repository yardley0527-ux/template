# 活動草稿（不代表已發送），見 CreateMarketingSuggestionsAndDrafts migration。
# 名單在建立當下用 Marketing::Segments 算好寫進 members 快照，之後原始資料變動不會改到。
class MarketingCampaignDraft < ApplicationRecord
  STATUSES = { "draft" => "草稿", "archived" => "已封存" }.freeze

  belongs_to :marketing_ai_suggestion, optional: true
  belongs_to :created_by, class_name: "User", foreign_key: :created_by_user_id
  has_many :members, class_name: "MarketingCampaignDraftMember", dependent: :delete_all

  validates :name, :segment_key, :rule_version, presence: true
  validates :status, inclusion: { in: STATUSES.keys }
  validates :planned_channel, inclusion: { in: Marketing::CardValidator::CHANNELS.keys }, allow_blank: true
  validate :products_exist
  validate :promotion_exists

  # 從客群（與可選的 AI 建議卡）建立草稿與名單快照
  def self.create_from_segment!(segment_key:, segment_params:, user:, attrs: {}, suggestion: nil, card_index: nil)
    result = Marketing::Segments.new.build(segment_key, segment_params)
    card = suggestion && card_index ? suggestion.cards[card_index] : nil
    transaction do
      draft = create!({
        name: card&.dig("title") || result.label, goal: card&.dig("goal"),
        marketing_ai_suggestion: suggestion, card_index: card && card_index, card_snapshot: card || {},
        segment_key: result.key, segment_params: result.params, rule_version: Marketing::Segments::RULE_VERSION,
        member_count: result.count, product_keys: card&.dig("product_keys") || Array(result.params["product_key"]),
        promotion_snapshot_id: card&.dig("promotion_id"), success_metric: card&.dig("success_metric"),
        planned_channel: card&.dig("channels")&.first, created_by: user
      }.merge(attrs.to_h.symbolize_keys))
      rows = result.members.map do |m|
        { marketing_campaign_draft_id: draft.id, manychat_subscriber_id: m["manychat_subscriber_id"],
          shopline_customer_id: m["shopline_customer_id"], identity_key: m["identity_key"], snapshot: m }
      end
      MarketingCampaignDraftMember.insert_all(rows) if rows.any?
      draft
    end
  end

  def segment_label = Marketing::Segments::DEFINITIONS.dig(segment_key, :label) || segment_key

  private

  def products_exist
    unknown = product_keys - CrmProduct.where(key: product_keys).pluck(:key)
    errors.add(:product_keys, "不存在：#{unknown.join('、')}") if unknown.any?
  end

  def promotion_exists
    return if promotion_snapshot_id.blank? || ProductPromotionSnapshot.exists?(promotion_snapshot_id)

    errors.add(:promotion_snapshot_id, "引用的優惠不存在")
  end
end
