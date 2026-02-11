# app/controllers/product_heavy_buyers_controller.rb
# frozen_string_literal: true

class ProductHeavyBuyersController < ApplicationController
  def index
    @product = params[:product].to_s.strip
    @match = params[:match].to_s.presence || "like" # exact | like | base
    @year = params[:year].to_i
    @year = nil if @year <= 0
    @min_units = params[:min_units].to_i
    @min_units = 1 if @min_units <= 0

    # ✅ 預設就用 like，避免「清纖粉」這種找不到
    exporter = Analytics::ProductHeavyBuyersExporter.new(
      product: @product,
      match: @match.to_sym,
      year: @year,
      min_units: @min_units
    )

    @result = exporter.call
    @rows = @result[:rows]
    @buyers_count = @result[:buyers_count]
    @suggestions = @result[:suggestions] || []
  end

  def export
    product = params[:product].to_s.strip
    match = params[:match].to_s.presence || "like"
    year = params[:year].to_i
    year = nil if year <= 0
    min_units = params[:min_units].to_i
    min_units = 1 if min_units <= 0

    result = Analytics::ProductHeavyBuyersExporter.new(
      product: product,
      match: match.to_sym,
      year: year,
      min_units: min_units
    ).call

    if result[:file].blank?
      redirect_to product_heavy_buyers_path(product: product, match: match, year: year, min_units: min_units),
                  alert: "沒有可匯出的資料"
      return
    end

    send_file result[:file], filename: File.basename(result[:file]), type: "text/csv"
  end
end
