module JourneyProducts
  extend ActiveSupport::Concern

  # 所有旅程管理支援的產品。新增產品只需在這裡加一筆，
  # 無需新增 Sidebar 或獨立 Controller。
  PRODUCTS = {
    "omnipotent" => {
      key:     "omnipotent",
      label:   "B群／全能",
      short:   "B群",
      icon:    "💊",
      color:   "#1d4ed8",
      sql:     "product_name LIKE '%全能%'",
      regex:   /全能(\d+)/,
      medians: { 1=>45, 2=>50, 3=>60, 4=>67, 6=>89, 10=>106, 12=>120 }
    },
    "metabolism" => {
      key:     "metabolism",
      label:   "代謝錠",
      short:   "代謝",
      icon:    "🔥",
      color:   "#dc2626",
      sql:     "product_name LIKE '%代謝%'",
      regex:   /代謝錠?(\d+)/,
      medians: { 1=>30, 2=>60, 3=>90 }
    },
    "glutathione" => {
      key:     "glutathione",
      label:   "穀胱甘肽",
      short:   "穀胱甘肽",
      icon:    "✨",
      color:   "#db2777",
      sql:     "product_name LIKE '%穀胱甘肽%'",
      regex:   /穀胱甘肽(\d+)/,
      medians: { 1=>30, 2=>60 }
    },
    "collagen" => {
      key:     "collagen",
      label:   "膠原飲",
      short:   "膠原",
      icon:    "💧",
      color:   "#0891b2",
      sql:     "product_name LIKE '%膠原%'",
      regex:   /膠原(?:蛋白)?(\d+)/,
      medians: { 1=>30, 2=>60 }
    },
    "turmeric" => {
      key:     "turmeric",
      label:   "薑黃",
      short:   "薑黃",
      icon:    "🌿",
      color:   "#d97706",
      sql:     "product_name LIKE '%薑黃%'",
      regex:   /薑黃(\d+)/,
      medians: { 1=>30, 2=>60, 3=>90 }
    }
  }.freeze

  DEFAULT_PRODUCT_KEY = "omnipotent"

  def set_product
    key          = params[:product].presence || DEFAULT_PRODUCT_KEY
    @product     = PRODUCTS[key] || PRODUCTS[DEFAULT_PRODUCT_KEY]
    @product_key = @product[:key]
    @all_products = PRODUCTS.values
  end
end
