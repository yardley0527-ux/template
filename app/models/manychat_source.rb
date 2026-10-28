# ManyChat 來源（內容入口）設定，見 AddEventTrackingToManychat migration 說明。
# key 是穩定 ID（建立後不改），name 可以改；raw_names 對應互動紀錄裡出現過的來源字串。
class ManychatSource < ApplicationRecord
  KEY_FORMAT = /\A[a-z0-9][a-z0-9_-]{1,60}\z/
  CONTENT_TYPES = {
    "post" => "貼文", "reel" => "Reel", "story" => "限動", "live" => "直播",
    "dm" => "私訊", "follow" => "新追蹤", "ad" => "廣告", "other" => "其他"
  }.freeze
  CHANNELS = %w[instagram facebook].freeze

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT }
  validates :name, :account_key, presence: true
  validates :channel, inclusion: { in: CHANNELS }
  validates :content_type, inclusion: { in: CONTENT_TYPES.keys }, allow_blank: true
  validate :product_keys_exist
  validate :raw_names_not_taken
  validate :key_unchanged, on: :update

  before_validation do
    self.raw_names = Array(raw_names).map { |n| n.to_s.strip }.reject(&:blank?).uniq
    self.product_keys = Array(product_keys).map(&:to_s).reject(&:blank?).uniq
  end

  # 互動紀錄的來源字串 → 設定。flow_event 的 source 直接是 key。
  def self.index_by_raw_name
    all.each_with_object({}) do |s, h|
      h[s.key] = s
      s.raw_names.each { |n| h[n] = s }
    end
  end

  def content_type_label = CONTENT_TYPES[content_type]

  private

  def product_keys_exist
    unknown = product_keys - CrmProduct.where(key: product_keys).pluck(:key)
    errors.add(:product_keys, "不存在：#{unknown.join('、')}") if unknown.any?
  end

  def raw_names_not_taken
    taken = self.class.where.not(id: id).where("raw_names && ARRAY[?]::varchar[]", raw_names.presence || [""])
                .flat_map(&:raw_names) & raw_names
    errors.add(:raw_names, "已被其他來源使用：#{taken.join('、')}") if taken.any?
  end

  def key_unchanged
    errors.add(:key, "建立後不能修改（是穩定 ID）") if will_save_change_to_key?
  end
end
