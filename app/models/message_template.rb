class MessageTemplate < ApplicationRecord
  has_many :message_template_blocks, -> { order(:position) }, dependent: :destroy

  validates :category_key, presence: true

  scope :in_category, ->(key, sub = nil) {
    where(category_key: key, subcategory: sub).order(:position)
  }

  CATEGORY_META = {
    "zhongzu"    => { title: "中租零卡分期", icon: "fa-credit-card", description: "付款提醒訊息" },
    "bulk"       => { title: "大組數",       icon: "fa-boxes",       description: "客人一次購買大量時使用" },
    "omnipotent" => { title: "全能膠囊",     icon: "fa-capsules",    description: "依序發送" },
    "whitening"  => { title: "美白膠囊",     icon: "fa-star",        description: "依序發送" },
    "metabolism" => { title: "代謝錠",       icon: "fa-fire",        description: "依序發送" },
  }.freeze

  BULK_SUBCATEGORIES = %w[全能 美白 全能＋美白 代謝錠 薑黃 益生菌 蝦紅素 清纖粉 膠原蛋白 魚油 私密粉 穀胱甘肽 D鈣 2.0面膜].freeze
  CATEGORY_ORDER     = %w[zhongzu bulk omnipotent whitening metabolism].freeze
end
