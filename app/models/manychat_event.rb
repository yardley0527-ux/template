# ManyChat Flow External Request 回傳的事件，見 AddEventTrackingToManychat migration 與
# docs/manychat_data_plan.md。只收白名單內的事件類型與屬性；(account_key, event_id) 去重，
# ManyChat 重送同一筆不會重複記錄。
#
# 語意注意：shop_link_sent 是「Flow 走到購物連結節點」，不代表客人點了連結；
# 任何事件都不代表客人已讀訊息。
class ManychatEvent < ApplicationRecord
  TOPICS = %w[skincare nutrition recipe product other].freeze
  CONSENT_CHANNELS = %w[ig_dm line email sms].freeze
  # 系統自己加的屬性（不是 Flow 傳來的）
  SYSTEM_PROPS = %w[event_time_from].freeze

  EVENT_TYPES = {
    "entry"                   => { label: "從內容入口進入", props: {} },
    "topic_selected"          => { label: "選擇有興趣的內容", props: { "topic" => TOPICS } },
    "info_requested"          => { label: "索取產品資訊", props: { "product_key" => :product } },
    "offer_requested"         => { label: "想了解優惠", props: { "product_key" => :product } },
    "purchase_help_requested" => { label: "需要購買協助", props: { "product_key" => :product } },
    "human_requested"         => { label: "要求真人協助", props: {} },
    "shop_link_sent"          => { label: "流程送出購物連結（不代表點擊）", props: { "product_key" => :product } },
    "binding_requested"       => { label: "申請綁定會員", props: {} },
    "consent_given"           => { label: "同意接收行銷訊息",
                                   props: { "channel" => CONSENT_CHANNELS, "purpose" => :text, "text_version" => :text },
                                   required: %w[channel purpose text_version] },
    "consent_withdrawn"       => { label: "取消行銷同意", props: { "channel" => CONSENT_CHANNELS }, required: %w[channel] }
  }.freeze

  belongs_to :manychat_subscriber, optional: true

  validates :account_key, format: { with: ManychatSubscriber::ACCOUNT_KEY_FORMAT }
  validates :subscriber_id, :event_id, :event_time, :received_at, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES.keys }
  validates :event_id, uniqueness: { scope: :account_key }
  validate :properties_allowed

  def event_type_label = EVENT_TYPES.dig(event_type, :label)

  # 只留白名單屬性，字串截到 100 字；不收姓名、電話、Email 等個資
  def self.clean_properties(event_type, raw)
    spec = EVENT_TYPES.dig(event_type, :props) || {}
    (raw.is_a?(Hash) ? raw : {}).slice(*spec.keys).transform_values { |v| v.to_s.strip[0, 100] }.reject { |_, v| v.blank? }
  end

  private

  def properties_allowed
    spec = EVENT_TYPES[event_type]
    return unless spec

    Array(spec[:required]).each { |k| errors.add(:properties, "缺少 #{k}") if properties[k].blank? }
    properties.except(*SYSTEM_PROPS).each do |k, v|
      rule = spec[:props][k]
      if rule.nil? then errors.add(:properties, "不接受 #{k}")
      elsif rule.is_a?(Array) && !rule.include?(v) then errors.add(:properties, "#{k} 只能是 #{rule.join('/')}")
      elsif rule == :product && !CrmProduct.exists?(key: v) then errors.add(:properties, "product_key 不存在：#{v}")
      end
    end
  end
end
