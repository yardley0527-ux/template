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
    },
    # ── 9/30 老闆要求加入的 4 個產品（key 跟 crm_products 同名，不需要 ProductKeyMapping 轉換）──
    # 魚油／蝦紅素 medians 直接取自 crm_repurchase_cycle_configs 的 historical_median
    # （魚油樣本 173/70/90/24/42、蝦紅素 287/133/110/80/36），數字要跟那張表一致，
    # CrmRepurchaseCycleConfigSeedService 才不會把它改掉。
    "fish_oil" => {
      key:          "fish_oil",
      label:        "魚油",
      short:        "魚油",
      icon:         "🐟",
      color:        "#0369a1",
      sql:          "product_name LIKE '%魚油%'",
      regex:        /魚油\s?(\d+)/,
      medians:      { 1=>45, 2=>45, 3=>114, 6=>119, 10=>157 },
      in_stock:     true,
      restock_date: nil
    },
    "astaxanthin" => {
      key:          "astaxanthin",
      label:        "蝦紅素",
      short:        "蝦紅素",
      icon:         "🦐",
      color:        "#ea580c",
      sql:          "product_name LIKE '%蝦紅素%'",
      regex:        /蝦紅素\s?(\d+)/,
      medians:      { 1=>44, 2=>49, 3=>112, 6=>145, 10=>153 },
      in_stock:     true,
      restock_date: nil
    },
    # PDRN 9/18 才首賣，沒有回購歷史：用使用者提供的用量（每瓶 60 顆、可吃 10–15 天），
    # 取中間值 12.5 天／瓶。買 10 瓶另有滿 2 萬送 1 瓶的贈品不在訂單資料裡，瓶數會低估。
    "pdrn" => {
      key:          "pdrn",
      label:        "PDRN",
      short:        "PDRN",
      icon:         "💉",
      color:        "#7c3aed",
      sql:          "product_name LIKE '%PDRN%'",
      regex:        /PDRN\s?(\d+)/,
      medians:      { 1=>13, 3=>38, 5=>63, 10=>125 },
      in_stock:     true,
      restock_date: nil
    },
    # 冰晶蕃茄 7/24 才上市，沒有回購歷史：沿用同一條白藜蘆醇美白膠囊線「美白」
    # （crm_repurchase_cycle_configs.whitening，2,087 位買家）的歷史中位數，這是推斷不是確定值。
    # 訂單裡同時有「番茄」「蕃茄」兩種寫法，還有「預購-」前綴，SQL 要兩種都抓。
    "iced_tomato" => {
      key:          "iced_tomato",
      label:        "冰晶蕃茄",
      short:        "冰晶",
      icon:         "🍅",
      color:        "#e11d48",
      sql:          "(product_name LIKE '%冰晶番茄%' OR product_name LIKE '%冰晶蕃茄%')",
      regex:        /冰晶[番蕃]茄\s?(\d+)/,
      medians:      { 1=>45, 2=>37, 3=>54, 4=>50, 6=>89, 10=>87 },
      in_stock:     true,
      restock_date: nil,
      # 「預購」訂單 9/25 才到貨（隱藏頁面「預購商品9/25到貨」），回購天數從到貨日起算。
      preorder_arrival: Date.new(2026, 9, 25)
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
