# frozen_string_literal: true

class IgEmailLookupController < ApplicationController
  # IG 帳號欄位常見帶 @ 前綴或前後空白，統一正規化後比對
  IG_NORM = "LOWER(REPLACE(TRIM(instagram_account), '@', ''))"

  def index
    @query = params[:q].to_s.strip
    return if @query.blank?

    needle = @query.downcase.delete_prefix("@")

    @customers = customers_matching(needle)
    @fuzzy = false

    if @customers.empty?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(needle)}%"
      @customers = customers_scope
        .where("#{IG_NORM} LIKE ?", like)
        .order(total_amount: :desc)
        .limit(20)
        .to_a
      @fuzzy = @customers.any?
    end

    # 客人主檔沒有 IG 時，訂單上可能有留 IG —— 用訂單反查 email 再撈客人
    if @customers.empty?
      emails = ShoplineOrder
        .where("#{IG_NORM} = ?", needle)
        .where.not(email: [nil, ""])
        .distinct
        .limit(20)
        .pluck(:email)
      if emails.any?
        @customers = customers_scope.where(email: emails).to_a
        @from_orders = true
        # 訂單有 email 但客人主檔還沒建檔的，也要能顯示
        missing = emails - @customers.map(&:email)
        @order_only_emails = missing
      end
    end
  end

  private

  def customers_scope
    ShoplineCustomer.select(
      :id, :full_name, :email, :mobile_phone,
      :membership_level, :instagram_account, :total_amount
    )
  end

  def customers_matching(needle)
    customers_scope
      .where("#{IG_NORM} = ?", needle)
      .order(total_amount: :desc)
      .to_a
  end
end
