# frozen_string_literal: true

require "test_helper"

# Shared helpers for the group_buy_crm read-only view tests (db/views/group_buy_crm_*_v01.sql).
#
# The views are queried through tiny read-only models, exactly how the separate group-buy-crm app
# will use them, so column types (including text[]) are cast the same way there.
module GroupBuyCrmViewTestHelper
  class ViewRecord < ActiveRecord::Base
    self.abstract_class = true
    def readonly? = true
  end

  class Member < ViewRecord
    self.table_name  = "group_buy_crm.members"
    self.primary_key = "shopline_customer_id"
  end

  class OrderLine < ViewRecord
    self.table_name  = "group_buy_crm.member_order_lines"
    self.primary_key = "order_line_key"
  end

  class ProductSummary < ViewRecord
    self.table_name  = "group_buy_crm.member_product_summaries"
    self.primary_key = nil
  end

  BASE_TIME = Time.utc(2026, 9, 1, 2, 0, 0)

  def build_customer(shopline_id:, email:, **attrs)
    ShoplineCustomer.create!({ shopline_id: shopline_id, full_name: "GB #{shopline_id}", email: email,
                               source_row_hash: "gbh-#{shopline_id}-#{SecureRandom.hex(4)}" }.merge(attrs))
  end

  def build_import_run(label = SecureRandom.hex(3))
    ImportRun.create!(kind: "paid_orders_workbook", file_name: "gb-#{label}.csv", file_checksum: SecureRandom.hex(8))
  end

  # customer: a ShoplineCustomer (sets shopline_customer_id); email defaults to the customer's email.
  def build_order(order_number:, product_name:, customer: nil, email: :from_customer, payment_status: "已付款",
                  quantity: 1, checkout_amount: 900, run: nil, order_date: BASE_TIME, customer_id: :from_customer)
    email = customer&.email if email == :from_customer
    customer_id = customer&.id if customer_id == :from_customer
    ShoplineOrder.create!(order_number: order_number, product_name: product_name, email: email,
                          payment_status: payment_status, quantity: quantity, checkout_amount: checkout_amount,
                          order_date: order_date, shopline_customer_id: customer_id, import_run_id: run&.id,
                          source_row_hash: "gbo-#{SecureRandom.hex(8)}")
  end

  def build_product(key, label = nil)
    CrmProduct.create!(key: key, label: label || "商品 #{key}", status: "confirmed")
  end

  # components: array of CrmProduct (bundle contents; may include the primary product itself)
  def build_mapping(raw_name, product, status: "confirmed_alias", source: "shopline_order", components: [])
    mapping = ProductNameMapping.create!(raw_name: raw_name, source: source, crm_product: product, mapping_status: status)
    components.each { |c| ProductMappingComponent.create!(product_name_mapping: mapping, crm_product: c, paid_quantity: 1) }
    mapping
  end

  def lines_for(order_number)
    OrderLine.where(order_number: order_number).to_a
  end

  def only_line(order_number)
    rows = lines_for(order_number)
    assert_equal 1, rows.size, "expected exactly 1 canonical line for #{order_number.inspect}, got #{rows.size}"
    rows.first
  end

  def summaries_for(customer)
    ProductSummary.where(shopline_customer_id: customer.id).to_a.index_by(&:product_key)
  end

  # The FK shopline_orders.shopline_customer_id -> shopline_customers currently makes a dangling id impossible.
  # The view still defends against it; drop the FK (rolled back with the test transaction) to prove that.
  def drop_orders_customer_fk!
    name = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT conname FROM pg_constraint
      WHERE contype = 'f' AND conrelid = 'shopline_orders'::regclass AND confrelid = 'shopline_customers'::regclass
    SQL
    ActiveRecord::Base.connection.execute("ALTER TABLE shopline_orders DROP CONSTRAINT #{name}") if name
  end
end
