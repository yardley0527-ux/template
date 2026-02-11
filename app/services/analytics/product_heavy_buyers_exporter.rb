# path: app/services/analytics/product_heavy_buyers_exporter.rb
# frozen_string_literal: true

require "csv"
require "fileutils"

module Analytics
  class ProductHeavyBuyersExporter
    MATCHES = %i[exact like base].freeze

    def initialize(product:, match: :like, min_units: 3, year: nil, out_dir: "tmp/exports")
      @product = product.to_s.strip
      @match = (match.presence || :like).to_sym
      @match = :like unless MATCHES.include?(@match)

      @min_units = min_units.to_i
      @min_units = 1 if @min_units <= 0

      y = year.to_i
      @year = (y <= 0 ? nil : y)

      @out_dir = out_dir
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      product_names = resolve_product_names

      if product_names.empty?
        return result_hash(rows: [], file: nil, suggestions: suggestions)
      end

      revenue_expr = revenue_expr_sql

      scope = ShoplineOrder
        .where.not(email: [nil, ""])
        .where.not(product_name: [nil, ""])
        .where(product_name: product_names)

      scope = scope.where(source_year: @year) if @year

      # rows: [email, orders_count, units_sold, revenue, first_order_at, last_order_at]
      rows = scope
        .group(Arel.sql("lower(email)"))
        .having("COALESCE(SUM(quantity),0) >= ?", @min_units)
        .pluck(
          Arel.sql("lower(email)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(quantity),0)"),
          Arel.sql("COALESCE(SUM(#{revenue_expr}),0)"),
          Arel.sql("MIN(order_date)"),
          Arel.sql("MAX(order_date)")
        )

      rows = rows.map do |email, orders_count, units_sold, revenue, first_at, last_at|
        {
          email: email,
          orders_count: orders_count.to_i,
          units_sold: units_sold.to_i,
          revenue: revenue.to_f.round(0).to_i,
          first_order_at: first_at,
          last_order_at: last_at
        }
      end

      rows.sort_by! { |r| [-r[:units_sold], -r[:revenue], -r[:orders_count], r[:email]] }

      customers = ShoplineCustomer
        .where("lower(email) IN (?)", rows.map { |r| r[:email] })
        .select(:id, :full_name, :email, :membership_level, :current_shopping_credits, :city)
        .to_a

      customer_by_email = customers.index_by { |c| c.email.to_s.strip.downcase }

      final = rows.map do |r|
        c = customer_by_email[r[:email]]
        r.merge(
          full_name: c&.full_name,
          membership_level: c&.membership_level,
          current_shopping_credits: c&.current_shopping_credits.to_f.round(0).to_i,
          city: c&.city
        )
      end

      ts = Time.zone.now.strftime("%Y%m%d_%H%M%S")
      safe = @product.gsub(/[^\p{L}\p{N}_-]+/u, "_")
      path = File.join(@out_dir, "product_heavy_buyers_#{safe}_#{ts}.csv")
      export_csv!(path, final)

      result_hash(rows: final, file: path, suggestions: (final.empty? ? suggestions : []))
    end

    private

    def result_hash(rows:, file:, suggestions:)
      {
        product: @product,
        match: @match,
        year: @year,
        min_units: @min_units,
        buyers_count: rows.size,
        rows: rows,
        file: file,
        suggestions: suggestions
      }
    end

    # ✅ checkout_amount 是單價 → * quantity
    def revenue_expr_sql
      if ShoplineOrder.column_names.include?("checkout_amount")
        "checkout_amount * quantity"
      else
        "total_amount"
      end
    end

    def resolve_product_names
      return [] if @product.blank?

      base = @product.sub(/\s*\d+\z/, "").strip

      case @match
      when :exact
        ShoplineOrder.where.not(product_name: [nil, ""]).where(product_name: @product).exists? ? [@product] : []
      when :like
        ShoplineOrder.where.not(product_name: [nil, ""])
          .where("product_name ILIKE ?", "%#{@product}%")
          .distinct.order(:product_name).limit(200).pluck(:product_name)
      when :base
        return [] if base.blank?
        ShoplineOrder.where.not(product_name: [nil, ""])
          .where("product_name ILIKE ?", "#{base}%")
          .distinct.order(:product_name).limit(200).pluck(:product_name)
      end
    end

    def export_csv!(path, rows)
      headers = ["客戶", "Email", "卡別", "購物金", "城市", "訂單數", "瓶數", "營收", "首購", "末購"]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        rows.each do |r|
          csv << [
            r[:full_name],
            r[:email],
            r[:membership_level],
            r[:current_shopping_credits],
            r[:city],
            r[:orders_count],
            r[:units_sold],
            r[:revenue],
            r[:first_order_at],
            r[:last_order_at]
          ]
        end
      end
    end

    # ✅ 清纖粉 → 同時提示 variants + 可能包含長名字（日本頂級天然清纖粉（一包））
    def suggestions
      return [] if @product.blank?
      k = @product.strip

      like = ShoplineOrder.where.not(product_name: [nil, ""])
        .where("product_name ILIKE ?", "%#{k}%")
        .distinct.order(:product_name).limit(12).pluck(:product_name)

      prefix = ShoplineOrder.where.not(product_name: [nil, ""])
        .where("product_name ILIKE ?", "#{k}%")
        .distinct.order(:product_name).limit(12).pluck(:product_name)

      (like + prefix).map { |s| s.to_s.strip }.reject(&:blank?).uniq.first(12)
    end
  end
end
