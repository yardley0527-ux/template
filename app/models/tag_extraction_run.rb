# path: app/models/tag_extraction_run.rb
# frozen_string_literal: true

# 一批「加 Tag 名單」抓取紀錄：這幾個系列在某段期間內、只買過一次的客人，
# 抓出來讓客服在 Omnichat 上加 tag 用。每批記錄抓取的日期區間，
# 讓下一次抓取知道要接著上次的 range_end 繼續抓。
class TagExtractionRun < ApplicationRecord
  CATEGORIES = {
    "代謝" => "%代謝%",
    "全能" => "%全能%",
    "清纖" => "%清纖%",
    "薑黃" => "%薑黃%",
    "膠原蛋白" => "%膠原蛋白%",
    "美白" => "%美白%"
  }.freeze

  # 不是特定系列，而是「全店史上第一筆已付款訂單」落在區間內的新客，走獨立邏輯。
  NEW_CUSTOMER_CATEGORY = "新客"

  ALL_CATEGORIES = (CATEGORIES.keys + [NEW_CUSTOMER_CATEGORY]).freeze

  # 新客名單顯示用：依首購 product_name 比對出是哪個系列，用來在頁面上顯示
  # 「新客－代謝 3」這種細項小計，跟 CATEGORIES 分開是因為新客不限系列、
  # product_name 是自由格式（含「預購-」「5送1」等），需要用關鍵字比對而非精準分類。
  NEW_CUSTOMER_PRODUCT_FAMILIES = {
    "代謝" => /代謝/,
    "全能" => /全能/,
    "清纖" => /清纖/,
    "薑黃" => /薑黃/,
    "膠原蛋白" => /膠原蛋白/,
    "美白" => /美白/,
    "私密粉" => /私密/,
    "益生菌" => /益生菌/,
    "冰晶蕃茄" => /冰晶(蕃|番)茄/,
    "穀胱甘肽" => /穀胱甘肽/
  }.freeze

  has_many :recipients, class_name: "TagExtractionRecipient", dependent: :destroy

  validates :range_start, :range_end, presence: true

  def new_customer_family_counts
    counts = Hash.new(0)

    recipients.where(category: NEW_CUSTOMER_CATEGORY).pluck(:product_name).each do |name|
      family = NEW_CUSTOMER_PRODUCT_FAMILIES.find { |_, pattern| name =~ pattern }&.first || "其他"
      counts[family] += 1
    end

    counts
  end
end
