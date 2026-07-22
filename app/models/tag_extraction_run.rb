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

  has_many :recipients, class_name: "TagExtractionRecipient", dependent: :destroy

  validates :range_start, :range_end, presence: true
end
