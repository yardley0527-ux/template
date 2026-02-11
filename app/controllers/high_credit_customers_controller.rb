# frozen_string_literal: true

class HighCreditCustomersController < ApplicationController
  def index
    @threshold = (params[:threshold].presence || 3000).to_i
    @year = params[:year].presence&.to_i
    @tab = params[:tab].to_s.presence || "customers" # customers | products
    @q = params[:q].to_s.strip

    @result = Analytics::CustomerProductExporter.new(
      threshold: @threshold,
      year: @year
    ).call

    if @tab == "products"
      @products = @result[:by_product]
      @products = @products.select { |g| g[:product_name].include?(@q) } if @q.present?
    else
      @customers = @result[:by_customer].map do |c|
        top = c[:products].first
        c.merge(products: top ? [top] : [])
      end
      if @q.present?
        @customers = @customers.select do |c|
          c[:full_name].to_s.include?(@q) ||
            c[:email].to_s.include?(@q) ||
            c[:line_id].to_s.include?(@q)
        end
      end
    end
  end

  # 下載 CSV（直接呼叫 service 產檔，然後 send_file）
  def export
    threshold = (params[:threshold].presence || 3000).to_i
    year = params[:year].presence&.to_i
    type = params[:type].to_s.presence || "customers" # customers | products

    result = Analytics::CustomerProductExporter.new(threshold: threshold, year: year).call
    path =
      case type
      when "products" then result[:files][:product_csv]
      else                 result[:files][:customer_csv]
      end

    send_file path, filename: File.basename(path), type: "text/csv"
  end
end
