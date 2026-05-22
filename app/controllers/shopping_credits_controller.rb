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
  end
end
