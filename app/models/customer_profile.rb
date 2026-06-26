# frozen_string_literal: true

class CustomerProfile < ApplicationRecord
  belongs_to :shopline_customer, class_name: "ShoplineCustomer"

  PRODUCT_TAG_OPTIONS = [
    "代謝錠",
    "全能",
    "薑黃",
    "膠原蛋白",
    "白藜蘆醇",
    "蝦紅素",
    "魚油",
    "清纖粉",
    "私密粉",
    "維DK鈣",
    "益生菌",
    "穀胱甘肽"
  ].freeze

  HEALTH_TAG_OPTIONS = [
    "睡眠",
    "腸胃",
    "便秘",
    "脹氣",
    "經期不規律",
    "囊腫",
    "肌瘤",
    "減重",
    "代謝",
    "血糖",
    "痘痘",
    "掉髮",
    "疲勞",
    "壓力",
    "過敏"
  ].freeze

  before_validation :normalize_tag_fields

  private

  def normalize_tag_fields
    self.product_tags = normalize_array(product_tags)
    self.health_tags  = normalize_array(health_tags)
  end

  def normalize_array(value)
    Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end
end