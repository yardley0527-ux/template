# 追蹤成效：待追蹤名單中已追蹤（有填追蹤備註）的客人，確認是否回購同一首購產品
class HighValueFollowUpResultsController < ApplicationController
  include HighValueOrderScoping

  LEVELS = HighValueOrderScoping::LEVELS

  def index
    @tab        = %w[repurchased pending].include?(params[:tab]) ? params[:tab] : 'repurchased'
    @start_date = parse_date(params[:start_date])
    @end_date   = parse_date(params[:end_date]) || @start_date
    @end_date   = @start_date if @start_date && @end_date && @end_date < @start_date

    @notes = OrderGiftRecord.where.not(follow_up_note: [nil, ""]).pluck(:order_number, :follow_up_note).to_h

    orders = @notes.empty? ? [] : build_scope.where("o.order_number IN (?)", @notes.keys).to_a
    if @start_date.present?
      orders.select! { |o| o.ord_date >= @start_date.beginning_of_day && o.ord_date <= @end_date.end_of_day }
    end
    orders = select_old_orders(orders)

    @products_by_order = build_products_by_order(orders)
    orders.select! { |o| (@products_by_order[o.order_num] || []).any? { |p| p[:prior_date].nil? } }

    @repurchases_by_order = build_repurchases(orders)

    repurchased, pending = orders.partition { |o| @repurchases_by_order[o.order_num].present? }
    @repurchased_count = repurchased.size
    @pending_count     = pending.size

    rows = @tab == 'repurchased' ? repurchased : pending
    @groups = LEVELS.map { |lvl| [lvl, rows.select { |o| o.membership_level_col == lvl }] }
  end

  private

  # 對每張已追蹤訂單的每個「首次購買」系列，找出訂單日之後最早的同系列已付款訂單
  def build_repurchases(orders)
    emails = orders.map(&:email_val).compact.uniq
    return {} if emails.empty?

    history = ShoplineOrder.where(email: emails)
                           .where("payment_status = '已付款'")
                           .pluck(:email, :product_name, :order_date, :order_number, :total_amount, :checkout_amount)

    order_totals = Hash.new { |h, k| h[k] = { max_total: nil, sum_checkout: 0 } }
    series_purchases = Hash.new { |h, k| h[k] = [] }
    history.each do |email, name, date, order_number, total_amount, checkout_amount|
      t = order_totals[order_number]
      t[:max_total] = [t[:max_total], total_amount].compact.reject(&:zero?).max
      t[:sum_checkout] += checkout_amount.to_f
      series_purchases[[email, product_series(name)]] << { date: date, order_number: order_number, product_name: name }
    end
    series_purchases.each_value { |list| list.sort_by! { |p| p[:date] } }

    orders.each_with_object({}) do |o, result|
      first_purchase_items = (@products_by_order[o.order_num] || []).select { |p| p[:prior_date].nil? }
      hits = first_purchase_items.filter_map do |p|
        series = product_series(p[:name])
        rep = series_purchases[[o.email_val, series]].find { |r| r[:date] > o.ord_date && r[:order_number] != o.order_num }
        next unless rep

        t = order_totals[rep[:order_number]]
        {
          series:        series,
          product_name:  rep[:product_name],
          date:          rep[:date],
          amount:        (t[:max_total] || t[:sum_checkout]).to_i,
          days_between:  (rep[:date].to_date - o.ord_date.to_date).to_i,
        }
      end
      result[o.order_num] = hits if hits.any?
    end
  end
end
