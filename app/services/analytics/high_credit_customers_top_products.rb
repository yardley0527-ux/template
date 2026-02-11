# frozen_string_literal: true

require "csv"
require "fileutils"

module Analytics
  class CustomerProductExporter
    def initialize(
      threshold: 3000,
      credit_column: :current_shopping_credits,
      limit_products_per_customer: 50,
      year: nil,
      out_dir: "tmp/exports"
    )
      @threshold = threshold.to_f
      @credit_column = credit_column.to_sym
      @limit_products_per_customer = limit_products_per_customer.to_i
      @year = year.presence&.to_i
      @out_dir = out_dir
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      customers = load_customers
      customer_ids = customers.map(&:id)
      email_to_customer_id = customers.each_with_object({}) do |c, h|
        e = c.email.to_s.strip.downcase
        h[e] = c.id if e.present?
      end
      emails = email_to_customer_id.keys

      orders_scope = ShoplineOrder.where.not(product_name: [nil, ""])
      orders_scope = orders_scope.where(source_year: @year) if @year.present?

      # 同時用 shopline_customer_id 與 email 兜
      orders_scope =
        orders_scope.where(shopline_customer_id: customer_ids)
                   .or(orders_scope.where(email: emails))

      revenue_col = revenue_column

      # pluck 出來後用 Ruby 聚合：避免 SQL group 因為 cid/email 混用而麻煩
      agg = Hash.new { |h, k| h[k] = { orders: 0, units: 0, revenue: 0.0 } }
      orders_scope.pluck(:shopline_customer_id, :email, :product_name, :quantity, revenue_col).each do |cid, email, pname, qty, rev|
        product_name = pname.to_s.strip
        next if product_name.blank?

        resolved_cid = cid || email_to_customer_id[email.to_s.strip.downcase]
        next unless resolved_cid

        k = [resolved_cid, product_name]
        agg[k][:orders] += 1
        agg[k][:units]  += qty.to_i
        agg[k][:revenue] += rev.to_f
      end

      # by_customer / by_product
      by_customer = Hash.new { |h, k| h[k] = [] }
      by_product  = Hash.new { |h, k| h[k] = [] }

      agg.each do |(cid, product_name), v|
        item = {
          customer_id: cid,
          product_name: product_name,
          orders_count: v[:orders],
          units_sold: v[:units],
          revenue: v[:revenue].round(0).to_i
        }
        by_customer[cid] << item
        by_product[product_name] << item
      end

      customers_by_id = customers.index_by(&:id)

      customer_list = customers.map do |c|
        items = by_customer[c.id]
                  .sort_by { |it| [-it[:units_sold], -it[:revenue], -it[:orders_count], it[:product_name]] }
                  .first(@limit_products_per_customer)

        {
          customer_id: c.id,
          full_name: c.full_name,
          email: c.email,
          line_id: c.line_id,
          phone: c.phone,
          mobile_phone: c.mobile_phone,
          city: c.city,
          membership_level: c.membership_level,
          credit_value: credit_value(c),
          products: items
        }
      end

      product_list = by_product.map do |product_name, items|
        enriched = items.map do |it|
          c = customers_by_id[it[:customer_id]]
          next unless c
          {
            product_name: product_name,
            customer_id: c.id,
            full_name: c.full_name,
            email: c.email,
            line_id: c.line_id,
            phone: c.phone,
            mobile_phone: c.mobile_phone,
            city: c.city,
            membership_level: c.membership_level,
            credit_value: credit_value(c),
            orders_count: it[:orders_count],
            units_sold: it[:units_sold],
            revenue: it[:revenue]
          }
        end.compact

        enriched.sort_by! { |r| [-r[:units_sold], -r[:revenue], -r[:orders_count], r[:full_name].to_s] }

        { product_name: product_name, customers: enriched }
      end

      product_list.sort_by! { |g| [-g[:customers].sum { |r| r[:units_sold] }, g[:product_name]] }

      ts = Time.zone.now.strftime("%Y%m%d_%H%M%S")
      customer_csv_path = File.join(@out_dir, "high_credit_customers_products_#{ts}.csv")
      product_csv_path  = File.join(@out_dir, "high_credit_products_customers_#{ts}.csv")

      export_customer_csv!(customer_csv_path, customer_list)
      export_product_csv!(product_csv_path, product_list)

      {
        threshold: @threshold,
        credit_column: @credit_column,
        year: @year,
        customers_count: customers.size,
        by_customer: customer_list,
        by_product: product_list,
        files: { customer_csv: customer_csv_path, product_csv: product_csv_path }
      }
    end

    private

    def load_customers
      raise ArgumentError, "unknown credit_column=#{@credit_column}" unless ShoplineCustomer.column_names.include?(@credit_column.to_s)

      ShoplineCustomer
        .where("#{@credit_column} > ?", @threshold)
        .select(
          :id, :full_name, :email, :line_id, :phone, :mobile_phone,
          :city, :membership_level, @credit_column
        )
        .to_a
    end

    def credit_value(customer)
      customer.public_send(@credit_column).to_f.round(0).to_i
    end

    def revenue_column
      ShoplineOrder.column_names.include?("checkout_amount") ? :checkout_amount : :total_amount
    end

    def export_customer_csv!(path, customer_list)
      headers = [
        "customer_id", "full_name", "email", "line_id", "phone", "mobile_phone", "city",
        "membership_level", "credit_value",
        "product_name", "orders_count", "units_sold", "revenue"
      ]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        customer_list.each do |c|
          if c[:products].blank?
            csv << [
              c[:customer_id], c[:full_name], c[:email], c[:line_id], c[:phone], c[:mobile_phone], c[:city],
              c[:membership_level], c[:credit_value],
              nil, 0, 0, 0
            ]
            next
          end

          c[:products].each do |p|
            csv << [
              c[:customer_id], c[:full_name], c[:email], c[:line_id], c[:phone], c[:mobile_phone], c[:city],
              c[:membership_level], c[:credit_value],
              p[:product_name], p[:orders_count], p[:units_sold], p[:revenue]
            ]
          end
        end
      end
    end

    def export_product_csv!(path, product_list)
      headers = [
        "product_name",
        "customer_id", "full_name", "email", "line_id", "phone", "mobile_phone", "city",
        "membership_level", "credit_value",
        "orders_count", "units_sold", "revenue"
      ]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        product_list.each do |g|
          g[:customers].each do |r|
            csv << [
              g[:product_name],
              r[:customer_id], r[:full_name], r[:email], r[:line_id], r[:phone], r[:mobile_phone], r[:city],
              r[:membership_level], r[:credit_value],
              r[:orders_count], r[:units_sold], r[:revenue]
            ]
          end
        end
      end
    end
  end
end
