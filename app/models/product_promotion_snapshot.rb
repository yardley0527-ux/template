# frozen_string_literal: true

class ProductPromotionSnapshot < ApplicationRecord
  scope :for_product, ->(product_key) { where(product_key: product_key).order(scraped_at: :desc) }

  def on_sale?
    discount_pct.positive?
  end
end
