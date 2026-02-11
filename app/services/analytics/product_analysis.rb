module Analytics
  class ProductAnalysis
    Result = Struct.new(
      :product_name,
      :orders_count,
      :units_sold,
      :revenue,
      :unique_customers,
      :avg_order_amount,
      :avg_units_per_order,
      :first_order_at,
      :last_order_at,
      :yearly_orders,
      :yearly_revenue,
      :monthly_orders,
      :monthly_revenue,
      :top_customers,
      :copurchase_top,
      keyword_init: true
    )

    def initialize(product_name:, limit: 20)
      @product_name = product_name.to_s.strip
      @limit = limit
    end

    def call
      scope = ShoplineOrder.where(product_name: @product_name)

      orders_count = scope.count
      units_sold = scope.sum(:quantity).to_i
      revenue = scope.sum(:total_amount).to_f
      unique_customers = scope.where.not(shopline_customer_id: nil).distinct.count(:shopline_customer_id)

      avg_order_amount = orders_count.zero? ? 0.0 : (revenue / orders_count)
      avg_units_per_order = orders_count.zero? ? 0.0 : (units_sold.to_f / orders_count)

      first_order_at = scope.minimum(:order_date)
      last_order_at = scope.maximum(:order_date)

      yearly_orders = scope.group(:source_year).count
      yearly_revenue = scope.group(:source_year).sum(:total_amount).transform_values { |v| v.to_f }

      monthly_orders = scope.group(:source_year, :source_month).count
      monthly_revenue = scope.group(:source_year, :source_month).sum(:total_amount).transform_values { |v| v.to_f }

      top_customers = top_customers_for(scope)
      copurchase_top = copurchase_top_for(scope)

      Result.new(
        product_name: @product_name,
        orders_count: orders_count,
        units_sold: units_sold,
        revenue: revenue,
        unique_customers: unique_customers,
        avg_order_amount: avg_order_amount,
        avg_units_per_order: avg_units_per_order,
        first_order_at: first_order_at,
        last_order_at: last_order_at,
        yearly_orders: yearly_orders,
        yearly_revenue: yearly_revenue,
        monthly_orders: monthly_orders,
        monthly_revenue: monthly_revenue,
        top_customers: top_customers,
        copurchase_top: copurchase_top
      )
    end

    private

    def top_customers_for(scope)
      rows = scope
        .where.not(shopline_customer_id: nil)
        .group(:shopline_customer_id)
        .select(
          "shopline_customer_id",
          "COUNT(*) AS orders_count",
          "COALESCE(SUM(quantity), 0) AS units_sold",
          "COALESCE(SUM(total_amount), 0) AS revenue"
        )
        .order(Arel.sql("revenue DESC"))
        .limit(@limit)

      customer_map = ShoplineCustomer.where(id: rows.map(&:shopline_customer_id))
        .pluck(:id, :full_name, :email, :membership_level)
        .to_h { |id, name, email, level| [id, { name: name, email: email, membership_level: level }] }

      rows.map do |r|
        info = customer_map[r.shopline_customer_id] || {}
        {
          customer_id: r.shopline_customer_id,
          full_name: info[:name],
          email: info[:email],
          membership_level: info[:membership_level],
          orders_count: r.orders_count.to_i,
          units_sold: r.units_sold.to_i,
          revenue: r.revenue.to_f
        }
      end
    end

    def copurchase_top_for(scope)
      # 找出「買過此商品」的客戶 -> 他們還買了什麼（排除自己）
      customer_ids = scope.where.not(shopline_customer_id: nil).distinct.pluck(:shopline_customer_id)
      return {} if customer_ids.empty?

      ShoplineOrder
        .where(shopline_customer_id: customer_ids)
        .where.not(product_name: [nil, "", @product_name])
        .group(:product_name)
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(@limit)
        .count
    end
  end
end