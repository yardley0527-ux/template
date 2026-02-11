# frozen_string_literal: true

module Analytics
  class HighCreditCustomersTopProducts
    Result = Struct.new(
      :threshold,
      :customers_count,
      :top_products_by_units,
      :top_products_by_orders,
      keyword_init: true
    )

    def initialize(threshold: 3000, limit: 20, year: nil)
      @threshold = threshold.to_f
      @limit = limit.to_i
      @year = year.presence&.to_i
    end

    def call
      customer_ids = high_credit_customer_ids

      # 防呆
      return Result.new(
        threshold: @threshold,
        customers_count: 0,
        top_products_by_units: [],
        top_products_by_orders: []
      ) if customer_ids.empty?

      scope = ShoplineOrder
                .where(shopline_customer_id: customer_ids)
                .where.not(product_name: [nil, ""])

      scope = scope.where(source_year: @year) if @year

      top_by_units = top_products(scope, order_sql: "units_sold DESC")
      top_by_orders = top_products(scope, order_sql: "orders_count DESC")

      Result.new(
        threshold: @threshold,
        customers_count: customer_ids.size,
        top_products_by_units: top_by_units,
        top_products_by_orders: top_by_orders
      )
    end

    private

    def high_credit_customer_ids
      ShoplineCustomer
        .where("current_shopping_credits > ?", @threshold)
        .where.not(id: nil)
        .pluck(:id)
    end

    # 回傳 array of hashes:
    # [{product_name:, units_sold:, orders_count:, revenue:}, ...]
    def top_products(scope, order_sql:)
      revenue_col = revenue_column

      rows = scope
               .select(
                 "product_name",
                 "COALESCE(SUM(quantity), 0) AS units_sold",
                 "COUNT(*) AS orders_count",
                 "COALESCE(SUM(#{revenue_col}), 0) AS revenue"
               )
               .group("product_name")
               .order(Arel.sql(order_sql))
               .limit(@limit)

      rows.map do |r|
        {
          product_name: r.product_name.to_s,
          units_sold: r.try(:units_sold).to_i,
          orders_count: r.try(:orders_count).to_i,
          revenue: r.try(:revenue).to_f
        }
      end
    end

    # revenue 口徑：checkout_amount 優先，否則 total_amount
    def revenue_column
      ShoplineOrder.column_names.include?("checkout_amount") ? "checkout_amount" : "total_amount"
    end
  end
end
