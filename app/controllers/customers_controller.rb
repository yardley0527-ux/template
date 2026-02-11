# path: app/controllers/customers_controller.rb
# frozen_string_literal: true

class CustomersController < ApplicationController
  PER_PAGE = 50
  MAX_PAGE = 200 # 防爆查詢

  def index
    @q = params[:q].to_s.strip
    @city = params[:city].to_s.strip
    @member = params[:member].to_s.strip # "" | "1" | "0"
    @min_credits = to_number(params[:min_credits])
    @min_points = to_number(params[:min_points])
    @sort = params[:sort].to_s.strip.presence || "credits_desc" # credits_desc | points_desc | newest | orders_desc

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    scope = ShoplineCustomer.all

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "full_name ILIKE :like OR email ILIKE :like OR mobile_phone ILIKE :like OR phone ILIKE :like OR instagram_account ILIKE :like",
        like: like
      )
    end

    scope = scope.where("city ILIKE ?", "%#{@city}%") if @city.present?

    if @member == "1"
      scope = scope.where(is_member: true)
    elsif @member == "0"
      scope = scope.where(is_member: [false, nil])
    end

    scope = scope.where("current_shopping_credits >= ?", @min_credits) if @min_credits
    scope = scope.where("current_points >= ?", @min_points) if @min_points

    scope = scope.where.not(email: [nil, ""]).or(scope.where.not(mobile_phone: [nil, ""])) # 基本可聯絡性

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = scope.count
    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0

    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)
  end

  private

  def to_number(v)
    s = v.to_s.strip
    return nil if s.blank?

    # 容忍 "3,000" / "3000.00"
    s = s.gsub(/[,\uFF0C]/, "")
    Float(s)
  rescue ArgumentError
    nil
  end

  def order_sql(sort)
    case sort
    when "points_desc"
      "current_points DESC NULLS LAST, id DESC"
    when "newest"
      "created_at DESC, id DESC"
    when "orders_desc"
      "order_count DESC NULLS LAST, id DESC"
    else
      "current_shopping_credits DESC NULLS LAST, id DESC"
    end
  end
end
