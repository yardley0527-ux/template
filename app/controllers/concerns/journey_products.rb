module JourneyProducts
  extend ActiveSupport::Concern

  # 所有旅程管理支援的產品。新增產品只需在這裡加一筆，
  # 無需新增 Sidebar 或獨立 Controller。
  #
  # in_stock / restock_date 是手動維護的庫存狀態（系統內沒有進銷存資料表），
  # 每次庫存異動時請直接更新這裡。「今日待辦」合併清單只會納入 in_stock: true 的產品。
  PRODUCTS = {
    "omnipotent" => {
      key:          "omnipotent",
      label:        "全能",
      short:        "B群",
      icon:         "💊",
      color:        "#1d4ed8",
      sql:          "product_name LIKE '%全能%'",
      regex:        /全能(\d+)/,
      medians:      { 1=>45, 2=>50, 3=>60, 4=>67, 6=>89, 10=>106, 12=>120 },
      in_stock:     false,
      restock_date: nil # 無到貨日
    },
    "metabolism" => {
      key:          "metabolism",
      label:        "代謝錠",
      short:        "代謝",
      icon:         "🔥",
      color:        "#dc2626",
      sql:          "product_name LIKE '%代謝%'",
      regex:        /代謝錠?(\d+)/,
      medians:      { 1=>30, 2=>60, 3=>90 },
      in_stock:     true,
      restock_date: nil
    },
    "glutathione" => {
      key:          "glutathione",
      label:        "穀胱甘肽",
      short:        "穀胱甘肽",
      icon:         "✨",
      color:        "#db2777",
      sql:          "product_name LIKE '%穀胱甘肽%'",
      regex:        /穀胱甘肽(\d+)/,
      medians:      { 1=>30, 2=>60 },
      in_stock:     false,
      restock_date: nil
    },
    "collagen" => {
      key:          "collagen",
      label:        "膠原蛋白",
      short:        "膠原",
      icon:         "💧",
      color:        "#0891b2",
      sql:          "product_name LIKE '%膠原%'",
      regex:        /膠原(?:蛋白)?(\d+)/,
      medians:      { 1=>30, 2=>60 },
      in_stock:     false,
      restock_date: Date.new(2026, 7, 20)
    },
    "turmeric" => {
      key:          "turmeric",
      label:        "薑黃",
      short:        "薑黃",
      icon:         "🌿",
      color:        "#d97706",
      sql:          "product_name LIKE '%薑黃%'",
      regex:        /薑黃(\d+)/,
      medians:      { 1=>30, 2=>60, 3=>90 },
      in_stock:     false,
      restock_date: Date.new(2026, 7, 17)
    },
    "qingxian" => {
      key:          "qingxian",
      label:        "清纖粉",
      short:        "清纖",
      icon:         "🌾",
      color:        "#65a30d",
      sql:          "product_name LIKE '%清纖粉%'",
      regex:        /清纖粉\s?(\d+)/,
      medians:      { 1=>90 }, # 無瓶數級距資料，暫用歷史平均回購週期
      in_stock:     true,
      restock_date: nil
    },
    "simi" => {
      key:          "simi",
      label:        "私密粉",
      short:        "私密粉",
      icon:         "🌸",
      color:        "#c026d3",
      sql:          "product_name LIKE '%私密粉%'",
      regex:        /私密粉\s?(\d+)/,
      medians:      { 1=>87 }, # 無瓶數級距資料，暫用歷史平均回購週期
      in_stock:     true,
      restock_date: nil
    },
    "probiotic" => {
      key:          "probiotic",
      label:        "益生菌",
      short:        "益生菌",
      icon:         "🦠",
      color:        "#0d9488",
      sql:          "product_name LIKE '%益生菌%'",
      regex:        /益生菌\s?(\d+)/,
      medians:      { 1=>46 }, # 無瓶數級距資料，暫用歷史平均回購週期
      in_stock:     true,
      restock_date: nil
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
