class MessageTemplate < ApplicationRecord
  has_many :message_template_blocks, -> { order(:position) }, dependent: :destroy

  validates :category_key, presence: true

  scope :in_category, ->(key, sub = nil) {
    where(category_key: key, subcategory: sub).order(:position)
  }

  CATEGORY_META = {
    "zhongzu"    => { title: "中租零卡分期", icon: "fa-credit-card",    description: "付款提醒訊息" },
    "bulk"       => { title: "新客訊息",     icon: "fa-boxes",          description: "客人一次購買大量時使用" },
    "big_set"    => { title: "大組數",       icon: "fa-layer-group",    description: "客人一次帶走大組數（多盒）時的售後關懷訊息，依產品挑選" },
    "omnipotent" => { title: "全能膠囊",     icon: "fa-capsules",       description: "依序發送" },
    "whitening"  => { title: "美白膠囊",     icon: "fa-star",           description: "依序發送" },
    "metabolism" => { title: "代謝錠",       icon: "fa-fire",           description: "依序發送" },
    "binding"    => { title: "會員綁定提醒", icon: "fa-link",           description: "提醒完成官網會員綁定與加入官方LINE" },
    "birthday"   => { title: "生日祝福",     icon: "fa-birthday-cake",  description: "會員生日祝福訊息，依情境挑選版本" },
    "upgrade"    => { title: "升級訊息",     icon: "fa-crown",          description: "會員升等通知訊息，依卡別挑選" },
    "turmeric"          => { title: "薑黃",     icon: "fa-pepper-hot", description: "依情境挑選版本" },
    "probiotics"        => { title: "益生菌",   icon: "fa-flask",      description: "依情境挑選版本" },
    "astaxanthin"       => { title: "蝦紅素",   icon: "fa-eye",        description: "依情境挑選版本" },
    "fiber_powder"      => { title: "清纖粉",   icon: "fa-weight",     description: "依情境挑選版本" },
    "collagen"          => { title: "膠原蛋白", icon: "fa-gem",        description: "依情境挑選版本" },
    "fish_oil"          => { title: "魚油",     icon: "fa-fish",       description: "依情境挑選版本" },
    "feminine_powder"   => { title: "私密粉",   icon: "fa-shield-alt", description: "依情境挑選版本" },
    "glutathione"       => { title: "穀胱甘肽", icon: "fa-sun",        description: "依情境挑選版本" },
    "vitamin_d_calcium" => { title: "D鈣",      icon: "fa-bone",       description: "依情境挑選版本" },
  }.freeze

  BULK_SUBCATEGORIES    = %w[全能 美白 全能＋美白 代謝錠 薑黃 益生菌 蝦紅素 清纖粉 膠原蛋白 魚油 私密粉 穀胱甘肽 D鈣 2.0面膜].freeze
  BIG_SET_SUBCATEGORIES = %w[全能 美白 代謝錠 薑黃 益生菌 蝦紅素 清纖粉 膠原蛋白 魚油 私密粉 穀胱甘肽 D鈣 2.0面膜].freeze
  UPGRADE_SUBCATEGORIES = %w[白卡 銀卡 金卡 黑卡].freeze
  SUBCATEGORY_MAP       = { "bulk" => BULK_SUBCATEGORIES, "big_set" => BIG_SET_SUBCATEGORIES, "upgrade" => UPGRADE_SUBCATEGORIES }.freeze
  CATEGORY_ORDER        = %w[binding zhongzu birthday upgrade bulk big_set].freeze
end
