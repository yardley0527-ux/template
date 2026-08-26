# frozen_string_literal: true

class CustomerProfile < ApplicationRecord
  belongs_to :shopline_customer, class_name: "ShoplineCustomer"

  PRODUCT_TAG_OPTIONS = [
    "維生素A", "維生素E", "維生素D", "維生素B", "維生素C",
    "鋅", "維生素D3", "鈣", "鎂", "鐵",
    "魚油", "Q10",
    "益生菌", "酵素",
    "葡萄糖胺", "軟骨素", "UC-II", "玻尿酸",
    "葉黃素", "蝦紅素",
    "薑黃",
    "膠原蛋白", "神經醯胺", "穀胱甘肽", "冰晶番茄",
    "蔓越莓", "甘露糖", "私密益生菌", "葉酸",
    "瑪卡",
    "藤黃果",
    "飲控代餐包",
    "高蛋白補充包",
    "GABA", "芝麻素", "褪黑激素",
    "白藜蘆醇", "NMN",
    "苦瓜胜肽",
    "納豆", "紅麴",
    "乳清蛋白",
    "肌酸",
    "瘦身產品"
  ].freeze

  SHENGTING_PRODUCT_OPTIONS = [
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
    "穀胱甘肽",
    "冰晶番茄"
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

  CUSTOMER_TYPE_OPTIONS = [
    "高潛力客",
    "穩定回購客",
    "流失回流客",
    "新客培養中",
    "高互動低消費",
    "流失高風險客"
  ].freeze

  before_validation :normalize_tag_fields
  before_save :stamp_stickiness_followed_up_at
  before_save :stamp_notes_updated_at

  validates :customer_type, inclusion: { in: CUSTOMER_TYPE_OPTIONS }, allow_blank: true

  private

  # 第一次填黏著度追蹤備註時記下追蹤時間；備註被清空則一併清掉，
  # 黏著度成效的回購判斷以此時間為準（同 OrderGiftRecord#stamp_followed_up_at）
  def stamp_stickiness_followed_up_at
    return unless stickiness_note_changed?

    self.stickiness_followed_up_at = stickiness_note.present? ? (stickiness_followed_up_at || Time.current) : nil
  end

  # 備註每次被改動就記下更新日期，讓「客人追蹤備註」卡片可以顯示備註編輯日期
  def stamp_notes_updated_at
    self.notes_updated_at = Time.current if notes_changed?
  end

  def normalize_tag_fields
    self.product_tags          = normalize_array(product_tags)
    self.health_tags           = normalize_array(health_tags)
    self.shengting_product_tags = normalize_array(shengting_product_tags)
  end

  def normalize_array(value)
    Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end
end