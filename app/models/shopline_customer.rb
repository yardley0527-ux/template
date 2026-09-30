# path: app/models/shopline_customer.rb
class ShoplineCustomer < ApplicationRecord
  self.table_name = "shopline_customers"

  has_many :shopline_orders, foreign_key: :shopline_customer_id, dependent: :nullify
  has_many :albums, dependent: :destroy

  has_one :customer_profile

  # 收件地址＝縣市(city) + 區(address_2) + 街道門牌(address_1)。
  # 有些客人的 address_1 已經寫了完整地址（含縣市／區，或超商、海外地址），
  # 這時不再往前補，避免「台北市中山區台北市中山區…」。沒有 address_1 回 nil。
  def full_address
    street = address_1.to_s.strip
    return nil if street.blank?

    variants = ->(s) { [s, s.sub("台", "臺"), s.sub("臺", "台")].uniq }
    return street if city.present? && variants.call(city.strip).any? { |v| street.include?(v) }

    parts = [city.to_s.strip]
    parts << address_2.to_s.strip unless address_2.to_s.strip.present? && street.include?(address_2.to_s.strip)
    (parts + [street]).reject(&:blank?).join
  end

  def self.normalize_email(v) = v.to_s.strip.downcase.presence
  def self.normalize_phone(v) = v.to_s.gsub(/\D+/, "").presence
  def self.normalize_ig(v)
    s = v.to_s.strip
    s = s.delete_prefix("@")
    s.downcase.presence
  end
end
