# frozen_string_literal: true

module Marketing
  # 顧客的已付款訂單（一張單一筆，整單金額取最大值，同 Manychat::LeadReport）與買過的產品。
  # 產品用 crm_customer_product_cycles（依 email 追蹤的產品購買），不靠商品名稱猜。
  class OrderIndex
    Order = Struct.new(:number, :at, :amount, keyword_init: true)

    def initialize(customer_ids)
      @customer_ids = customer_ids.compact.uniq
    end

    def orders_for(customer_id)
      orders[customer_id] || []
    end

    def bought_product?(customer_id, product_key)
      products[customer_id]&.include?(product_key)
    end

    private

    def orders
      @orders ||= if @customer_ids.empty? then {}
                  else
                    ShoplineOrder.where(shopline_customer_id: @customer_ids, payment_status: "已付款").where.not(order_date: nil)
                                 .group(:shopline_customer_id, :order_number)
                                 .pluck(:shopline_customer_id, :order_number, Arel.sql("MIN(order_date)"), Arel.sql("MAX(total_amount)"))
                                 .group_by(&:first)
                                 .transform_values { |rows| rows.map { |_, n, at, amt| Order.new(number: n, at: at, amount: amt.to_f) } }
                  end
    end

    def products
      @products ||= begin
        emails = ShoplineCustomer.where(id: @customer_ids).where.not(email: [nil, ""]).pluck(:id, :email)
        by_email = emails.to_h { |id, e| [e.strip.downcase, id] }
        CrmCustomerProductCycle.where(email: by_email.keys).distinct.pluck(:email, :product_key)
                               .each_with_object(Hash.new { |h, k| h[k] = Set.new }) { |(e, p), h| h[by_email[e]] << p }
      end
    end
  end
end
