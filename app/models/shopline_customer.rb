# path: app/models/shopline_customer.rb
class ShoplineCustomer < ApplicationRecord
  self.table_name = "shopline_customers"

  has_many :shopline_orders, foreign_key: :shopline_customer_id, dependent: :nullify

  def self.normalize_email(v) = v.to_s.strip.downcase.presence
  def self.normalize_phone(v) = v.to_s.gsub(/\D+/, "").presence
  def self.normalize_ig(v)
    s = v.to_s.strip
    s = s.delete_prefix("@")
    s.downcase.presence
  end
end
