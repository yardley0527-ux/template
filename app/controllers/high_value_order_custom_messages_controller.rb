class HighValueOrderCustomMessagesController < ApplicationController
  PRODUCTS           = %w[全能 美白 代謝錠 薑黃 益生菌 蝦紅素 清纖粉 膠原蛋白 魚油 私密粉 穀胱甘肽 D鈣 2.0面膜].freeze
  FIRST_PURCHASE_PRODUCTS = PRODUCTS - ["2.0面膜"]
  SEND_PRODUCT_ITEMS = %w[會員小物 禮物].freeze

  CATEGORIES = [
    { key: "custom_first_purchase", title: "首購訊息",   icon: "fa-gem",    description: "依產品分類的首購客訊息",     subcategories: FIRST_PURCHASE_PRODUCTS },
    { key: "custom_send_product",   title: "送產品訊息", icon: "fa-box",    description: "出貨/送出產品時使用的訊息", subcategories: SEND_PRODUCT_ITEMS },
    { key: "custom_gift",           title: "贈品訊息",   icon: "fa-heart",  description: "依產品分類的贈品訊息",       subcategories: PRODUCTS },
  ].freeze

  def index
    @categories = CATEGORIES.map do |cat|
      subcategories = cat[:subcategories].map do |name|
        { name: name, templates: MessageTemplate.in_category(cat[:key], name) }
      end
      { key: cat[:key], title: cat[:title], icon: cat[:icon], description: cat[:description], subcategories: subcategories }
    end
  end
end
