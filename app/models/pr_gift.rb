# frozen_string_literal: true

# 公關品（老闆送給客人的產品）。一次送一筆，同一位客人可以有很多筆。
class PrGift < ApplicationRecord
  UNITS = %w[瓶 盒 包 組 個].freeze
  # 沒列在這裡的產品預設用「瓶」；膠原蛋白是盒裝
  DEFAULT_UNITS = { "膠原蛋白" => "盒" }.freeze

  belongs_to :shopline_customer

  validates :product_name, presence: true, length: { maximum: 50 }
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 999 }
  validates :unit, inclusion: { in: UNITS }
  validates :given_on, presence: true
  validates :note, length: { maximum: 100 }

  scope :recent_first, -> { order(given_on: :desc, id: :desc) }

  def self.default_unit_for(product_name)
    DEFAULT_UNITS.fetch(product_name.to_s, "瓶")
  end

  def summary
    "#{product_name} ×#{quantity}#{unit}"
  end
end
