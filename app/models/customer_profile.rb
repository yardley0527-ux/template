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

  before_validation :normalize_product_tags

  private

  def normalize_product_tags
    self.product_tags = Array(product_tags)
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end