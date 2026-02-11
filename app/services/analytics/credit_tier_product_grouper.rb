# frozen_string_literal: true

require "csv"
require "fileutils"

module Analytics
  class CreditTierProductGrouper
    def initialize(
      threshold: 3000,
      year: nil,
      tiers: nil,
      out_dir: "tmp/exports"
    )
      @threshold = threshold.to_i
      @year = year.presence&.to_i
      @tiers = tiers.presence || default_tiers
      @out_dir = out_dir
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      customers_scope = ShoplineCustomer
        .where("current_shopping_credits >= ?", @threshold)
        .where.not(email: [nil, ""])

      customers_scope = customers_scope.select(
        :id, :full_name, :email, :line_id, :phone, :mobile_phone,
        :city, :membership_level, :current_shopping_credits
      )

      # 先把客人撈出來（避免每個 tier 重複 hit DB）
      customers = customers_scope.to_a
      customers_by_email = customers.group_by { |c| normalize_email(c.email) }

      tiers_result = @tiers.map do |t|
        tier_customers = customers.select do |c|
          credits = c.current_shopping_credits.to_f
          credits >= t[:min] && (t[:max].nil? || credits <= t[:max])
        end

        tier_emails = tier_customers.map { |c| normalize_email(c.email) }.uniq

        products = group_products_for_emails(tier_emails, customers_by_email)

        {
          key: t[:key],
          min: t[:min],
          max: t[:max],
          customers_count: tier_customers.size,
          products: products
        }
      end

      ts = Time.zone.now.strftime("%Y%m%d_%H%M%S")
      tier_product_csv = File.join(@out_dir, "credit_tier_products_#{ts}.csv")
      tier_customers_csv = File.join(@out_dir, "credit_tier_customers_#{ts}.csv")

      export_tier_product_csv!(tier_product_csv, tiers_result)
      export_tier_customers_csv!(tier_customers_csv, tiers_result)

      {
        threshold: @threshold,
        year: @year,
        tiers: tiers_result,
        files: {
          tier_product_csv: tier_product_csv,
          tier_customers_csv: tier_customers_csv
        }
      }
    end

    private

    def default_tiers
      [
        { key: "3000-4999",  min: 3000,  max: 4999 },
        { key: "5000-9999",  min: 5000,  max: 9999 },
        { key: "10000-19999", min: 10000, max: 19999 },
        { key: "20000+",      min: 20000, max: nil }
      ]
    end

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    def revenue_col
      if ShoplineOrder.column_names.include?("checkout_amount")
        "checkout_amount * quantity"
      else
        "total_amount"
      end
    end

    def group_products_for_emails(emails, customers_by_email)
      return [] if emails.blank?

      scope = ShoplineOrder.where("lower(email) IN (?)", emails)
      scope = scope.where(source_year: @year) if @year.present?
      scope = scope.where.not(product_name: [nil, ""])

      # 用 email + product group（因為 FK 不可靠）
      rows = scope.group(Arel.sql("lower(email)"), :product_name).pluck(
        Arel.sql("lower(email)"),
        :product_name,
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(quantity),0)"),
        Arel.sql("COALESCE(SUM(#{revenue_col}),0)")
      )

      # product_name => [customer rows...]
      by_product = Hash.new { |h, k| h[k] = [] }

      rows.each do |email, product_name, orders_count, units_sold, revenue|
        next if product_name.to_s.strip.empty?

        # 同一 email 可能對到多筆 customer（理論上不會，但防呆）
        cs = customers_by_email[email] || []
        cs.each do |c|
          by_product[product_name.to_s.strip] << {
            customer_id: c.id,
            full_name: c.full_name,
            email: c.email,
            line_id: c.line_id,
            phone: c.phone,
            mobile_phone: c.mobile_phone,
            city: c.city,
            membership_level: c.membership_level,
            credits: c.current_shopping_credits.to_f.round(0).to_i,
            orders_count: orders_count.to_i,
            units_sold: units_sold.to_i,
            revenue: revenue.to_f.round(0).to_i
          }
        end
      end

      by_product.map do |pname, list|
        list.sort_by! { |r| [-r[:units_sold], -r[:revenue], -r[:orders_count], r[:customer_id]] }

        {
          product_name: pname,
          customers_count: list.map { |r| r[:customer_id] }.uniq.size,
          units_sold: list.sum { |r| r[:units_sold] },
          revenue: list.sum { |r| r[:revenue] },
          customers: list
        }
      end.sort_by { |g| [-g[:customers_count], -g[:units_sold], -g[:revenue], g[:product_name]] }
    end

    def export_tier_product_csv!(path, tiers)
      headers = ["tier", "product_name", "customers_count", "units_sold", "revenue"]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        tiers.each do |t|
          t[:products].each do |p|
            csv << [t[:key], p[:product_name], p[:customers_count], p[:units_sold], p[:revenue]]
          end
        end
      end
    end

    def export_tier_customers_csv!(path, tiers)
      headers = [
        "tier", "product_name",
        "customer_id", "full_name", "email", "line_id", "mobile_phone", "city",
        "membership_level", "credits",
        "orders_count", "units_sold", "revenue"
      ]

      CSV.open(path, "wb", write_headers: true, headers: headers) do |csv|
        tiers.each do |t|
          t[:products].each do |p|
            p[:customers].each do |c|
              csv << [
                t[:key], p[:product_name],
                c[:customer_id], c[:full_name], c[:email], c[:line_id], c[:mobile_phone], c[:city],
                c[:membership_level], c[:credits],
                c[:orders_count], c[:units_sold], c[:revenue]
              ]
            end
          end
        end
      end
    end
  end
end
