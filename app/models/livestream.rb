class Livestream < ApplicationRecord
  # product_keys＝「本場銷售產品」：該場直播中可付費購買的產品（crm_products.key），
  # 包含付費的主打、搭配、組合成分與加購商品；純贈品（商品名中「送X」「贈X」的 X）不列入。
  # UI 顯示一律稱「本場銷售產品」，不得稱「主打產品」。
  #
  # reported_orders / reported_revenue＝「歷史登記訂單／歷史登記營收」，來源與衝突紀錄
  # 見 db/data/livestream_reconciliation.yml；NULL＝無可信登記值，UI 顯示「—」。
  #
  # analysis_note 已 deprecated：全 codebase 無讀寫，本階段不使用、不移除（cleanup 另案）。
  has_many :livestream_images, -> { order(position: :asc) }, dependent: :destroy
  has_many :livestream_products, -> { order(position: :asc) }, dependent: :destroy
  has_many :livestream_gifts, -> { order(position: :asc) }, dependent: :destroy

  validates :date, presence: true, uniqueness: true

  before_validation { self.product_keys = product_keys.reject(&:blank?) if product_keys }

  default_scope { order(date: :desc) }
end
