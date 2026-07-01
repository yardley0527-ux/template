# frozen_string_literal: true

# Extracts the number of bottles/boxes from a raw product_name string.
# Centralises the logic previously duplicated across 6 controllers and services.
#
# Usage:
#   BottleExtractor.call("薑黃3", "turmeric")   # => 3
#   BottleExtractor.call("代謝家庭號", "metabolism") # => 6
#   BottleExtractor.call("全能（3盒）", "omnipotent") # => 3
#   BottleExtractor.call("美白10+1送1", "whitening") # => 12
class BottleExtractor
  BRACKET_PATTERN = /[（(](\d+)[瓶盒]/.freeze
  BONUS_PATTERN   = /送(\d+)/.freeze

  # Substring overrides that cannot be captured by a numeric regex.
  # { product_key => { substring => bottle_count } }
  SUBSTRING_OVERRIDES = {
    "metabolism" => { "家庭號" => 6 }
  }.freeze

  def self.call(product_name, product_key)
    new(product_key).extract(product_name)
  end

  def initialize(product_key)
    @product_key = product_key
    @regex       = build_regex(product_key)
    @overrides   = SUBSTRING_OVERRIDES[@product_key.to_s] || {}
  end

  def extract(product_name)
    return 1 if product_name.blank?

    @overrides.each do |substring, count|
      return count if product_name.include?(substring)
    end

    base = if @regex && (m = product_name.match(@regex))
      m[1].to_i
    elsif (m = product_name.match(BRACKET_PATTERN))
      m[1].to_i
    else
      1
    end

    base + bonus(product_name)
  end

  private

  def build_regex(product_key)
    crm = CrmProduct.find_by(key: product_key.to_s)
    return nil unless crm&.regex_pattern.present?
    Regexp.new(crm.regex_pattern)
  rescue RegexpError
    nil
  end

  def bonus(product_name)
    product_name.match(BONUS_PATTERN)&.[](1).to_i || 0
  end
end
