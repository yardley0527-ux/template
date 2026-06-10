# frozen_string_literal: true

class ShoppingCreditsController < ApplicationController
  LEVELS = %w[黑卡 金卡 銀卡 白卡].freeze

  def index
    base = ShoplineCustomer
      .where("current_shopping_credits > 0")
      .where.not(membership_expiry_date: nil)

    @level_totals = LEVELS.index_with do |level|
      base.where(membership_level: level).sum(:current_shopping_credits)
    end
    @grand_total = @level_totals.values.sum

    rows = base
      .group(
        Arel.sql("DATE_TRUNC('month', membership_expiry_date)"),
        :membership_level
      )
      .order(Arel.sql("DATE_TRUNC('month', membership_expiry_date) ASC"))
      .sum(:current_shopping_credits)

    months = rows.keys.map(&:first).uniq.sort
    @rows = months.map do |month|
      credits = LEVELS.index_with { |lv| rows[[month, lv]] || 0 }
      { month: month, credits: credits, total: credits.values.sum }
    end

    # 高購物金名單（超過 1 萬），依卡別分群 + 分頁
    HC_PER_PAGE = 10
    high_credits = ShoplineCustomer
      .where("current_shopping_credits >= 10000")
      .where(membership_level: LEVELS)
      .select(:id, :full_name, :email, :membership_level, :current_shopping_credits, :membership_expiry_date, :instagram_account)
      .order(current_shopping_credits: :desc)
    @high_credits_grouped = LEVELS.index_with { |lv| high_credits.select { |c| c.membership_level == lv } }

    @hc_level = params[:hc_level].presence
    @hc_page  = [params[:hc_page].to_i, 1].max
    if @hc_level
      all = @high_credits_grouped[@hc_level] || []
      @hc_pages      = (all.size / HC_PER_PAGE.to_f).ceil.clamp(1, Float::INFINITY)
      @hc_page       = @hc_page.clamp(1, @hc_pages)
      @hc_current    = all.each_slice(HC_PER_PAGE).to_a[@hc_page - 1] || []
    end
  end
end
