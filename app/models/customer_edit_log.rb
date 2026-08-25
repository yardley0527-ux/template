class CustomerEditLog < ApplicationRecord
  belongs_to :customer, class_name: "ShoplineCustomer", optional: true
  belongs_to :user, optional: true

  SECTION_LABELS = {
    "notes"       => "備註 / 健康資料",
    "tags"        => "標籤",
    "ambassador"  => "品牌大使",
    "feedback"    => "回饋意見",
    "attention"   => "特殊關注"
  }.freeze

  FIELD_LABELS = {
    "notes"                       => "備註",
    "health_profile"              => "健康資料",
    "feedback"                    => "回饋意見",
    "special_attention"           => "特殊關注",
    "product_tags"                => "產品偏好",
    "shengting_product_tags"      => "購買過苼莛的產品",
    "health_tags"                 => "健康標籤",
    "brand_ambassador_training"   => "品牌大使培訓",
    "brand_ambassador_blacklisted"=> "大使黑名單",
    "blacklisted"                 => "黑名單",
    "churned"                     => "已流失"
  }.freeze
end
