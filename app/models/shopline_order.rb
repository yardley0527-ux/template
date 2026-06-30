# path: app/models/shopline_order.rb
class ShoplineOrder < ApplicationRecord
  self.table_name = "shopline_orders"

  belongs_to :shopline_customer, optional: true
  belongs_to :import_run, optional: true

  # Valid paid orders only — order_status is always NULL in this dataset
  scope :valid_paid, -> {
    where(payment_status: "已付款")
      .where.not(order_number: [nil, ""])
      .where.not(email: [nil, ""])
      .where.not(order_date: nil)
  }
end
