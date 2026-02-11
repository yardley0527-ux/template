# app/controllers/credit_tiers_controller.rb
# frozen_string_literal: true

class CreditTiersController < ApplicationController
  def index
    @threshold = (params[:threshold].presence || 3000).to_i
    @year = params[:year].presence&.to_i
    @q = params[:q].to_s.strip # 商品關鍵字
    @limit_products = (params[:limit_products].presence || 20).to_i
    @limit_customers = (params[:limit_customers].presence || 50).to_i

    @result = Analytics::CreditTierProductGrouper.new(
      threshold: @threshold,
      year: @year
    ).call

    # 依商品關鍵字 filter（每個 tier 內）
    if @q.present?
      @result[:tiers].each do |t|
        t[:products] = t[:products].select { |p| p[:product_name].to_s.include?(@q) }
      end
    end

    # 每個 tier 限制顯示的 products / customers 數量（避免頁面爆炸）
    @result[:tiers].each do |t|
      t[:products] = t[:products].first(@limit_products)
      t[:products].each do |p|
        p[:customers] = p[:customers].first(@limit_customers)
      end
    end
  end

  # 下載 CSV：兩種
  # type=products  => tier_product_csv（每個 tier 的產品彙總）
  # type=customers => tier_customers_csv（tier+product 下的客人名單）
  def export
    threshold = (params[:threshold].presence || 3000).to_i
    year = params[:year].presence&.to_i
    type = params[:type].to_s.presence || "products"

    result = Analytics::CreditTierProductGrouper.new(threshold: threshold, year: year).call
    path =
      case type
      when "customers" then result[:files][:tier_customers_csv]
      else                  result[:files][:tier_product_csv]
      end

    send_file path, filename: File.basename(path), type: "text/csv"
  end
end
