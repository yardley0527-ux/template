# path: app/services/analytics/customer_product_exporter.rb
# frozen_string_literal: true

require "csv"
require "fileutils"

module Analytics
  class CustomerProductExporter
    def initialize(
      threshold: 3000,
      credit_column: :current_shopping_credits,
      year: nil,
      out_dir: "tmp/exports",
      limit_products_per_customer: 50
    )
      @threshold = threshold.to_f
      @credit_column = credit_column.to_sym
      @year = year.presence&.to_i
      @out_dir = out_dir
      @limit_products_per_customer = limit_products_per_customer.to_i
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      customers = load_customers
      emails = customers.map { |c| normalize_email(c.email) }.compact.uniq

      orders = ShoplineOrder.where.not(product_name: [nil, ""])
      orders = orders.where(source_year: @year) if @year.present?
      orders = orders.where("lower(email) IN (?)", emails)

      revenue_col = revenue_column

      agg = Hash.new do |h, email|
        h[email] = Hash.new { |hh, product| hh[product] = { orders: 0, units: 0, revenue: 0 } }
      end

        orders.pluck(:email, :product_name, :quantity, Arel.sql(revenue_col)).each do |email, product_name, qty, rev|        e = normalize_email(email)
        next if e.blank?

        pname = product_name.to_s.strip
        next if pname.blank?

        a = agg[e][pname]
        a[:orders] += 1
        a[:units] += qty.to_i
        a[:revenue] += rev.to_f.round(0).to_i
      end

      by_customer = customers.map do |c|
        e = normalize_email(c.email)

        products =
          agg[e].map do |pname, a|
            {
              product_name: pname,
              orders_count: a[:orders],
              units_sold: a[:units],
              revenue: a[:revenue]
            }
          end

        products.sort_by! { |p| [-p[:units_sold], -p[:revenue], -p[:orders_count], p[:product_name]] }
        products = products.first(@limit_products_per_customer)

        {
          customer_id: c.id,
          full_name: c.full_name,
          email: c.email,
          line_id: c.line_id,
          mobile_phone: c.mobile_phone,
          city: c.city,
          membership_level: c.membership_level,
          credit_value: credit_value(c),
          products: products
        }
      end

      by_product_hash = Hash.new { |h, k| h[k] = [] }

      by_customer.each do |c|
        c[:products].each do |p|
          by_product_hash[p[:product_name]] << {
            product_name: p[:product_name],
            customer_id: c[:customer_id],
            full_name: c[:full_name],
            email: c[:email],
            line_id: c[:line_id],
            mobile_phone: c[:mobile_phone],
            city: c[:city],
            membership_level: c[:membership_level],
            credit_value: c[:credit_value],
            orders_count: p[:orders_count],
            units_sold: p[:units_sold],
            revenue: p[:revenue]
          }
        end
      end

      by_product =
        by_product_hash.map do |product_name, rows|
          rows.sort_by! { |r| [-r[:units_sold], -r[:revenue], -r[:orders_count], r[:full_name].to_s] }
          { product_name: product_name, customers: rows }
        end

      by_product.sort_by! { |g| [-g[:customers].sum { |r| r[:units_sold] }, g[:product_name]] }

      ts = Time.zone.now.strftime("%Y%m%d_%H%M%S")
      customer_csv_path = File.join(@out_dir, "high_credit_customers_products_#{ts}.csv")
      product_csv_path = File.join(@out_dir, "high_credit_products_customers_#{ts}.csv")

      export_customer_csv!(customer_csv_path, by_customer)
      export_product_csv!(product_csv_path, by_product)

      {
        threshold: @threshold,
        credit_column: @credit_column,
        year: @year,
        customers_count: customers.size,
        by_customer: by_customer,
        by_product: by_product,
        files: { customer_csv: customer_csv_path, product_csv: product_csv_path }
      }
    end

    private
    def revenue_column
      if ShoplineOrder.column_names.include?("checkout_amount")
        "checkout_amount * quantity"
      else
        "total_amount"
      end
    end

    def normalize_email(email)
      email.to_s.strip.downcase.presence
    end

    def load_customers
      unless ShoplineCustomer.column_names.include?(@credit_column.to_s)
        raise ArgumentError, "unknown credit_column=#{@credit_column}"
      end

      ShoplineCustomer
        .where("#{@credit_column} > ?", @threshold)
        .select(:id, :full_name, :email, :line_id, :mobile_phone, :city, :membership_level, @credit_column)
        .to_a
    end

    def credit_value(customer)
      customer.public_send(@credit_column).to_f.round(0).to_i
    end

    def export_customer_csv!(path, by_customer)
      headers = %w[
        customer_id full_name email line_id mobile_phone city membership_level credit_value
        product_name orders_count units_sold revenue
      ]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        by_customer.each do |c|
          if c[:products].blank?
            csv << [
              c[:customer_id], c[:full_name], c[:email], c[:line_id], c[:mobile_phone], c[:city],
              c[:membership_level], c[:credit_value], nil, 0, 0, 0
            ]
            next
          end

          c[:products].each do |p|
            csv << [
              c[:customer_id], c[:full_name], c[:email], c[:line_id], c[:mobile_phone], c[:city],
              c[:membership_level], c[:credit_value],
              p[:product_name], p[:orders_count], p[:units_sold], p[:revenue]
            ]
          end
        end
      end
    end

    def export_product_csv!(path, by_product)
      headers = %w[
        product_name customer_id full_name email line_id mobile_phone city membership_level credit_value
        orders_count units_sold revenue
      ]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        by_product.each do |g|
          g[:customers].each do |r|
            csv << [
              g[:product_name],
              r[:customer_id], r[:full_name], r[:email], r[:line_id], r[:mobile_phone], r[:city],
              r[:membership_level], r[:credit_value],
              r[:orders_count], r[:units_sold], r[:revenue]
            ]
          end
        end
      end
    end
  end
end
