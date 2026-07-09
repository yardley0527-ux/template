# 待追蹤名單：破8000舊客訂單中，含「首次購買」產品的客人，依卡別分群
class HighValueFollowUpsController < ApplicationController
  include HighValueOrderScoping

  LEVELS = HighValueOrderScoping::LEVELS

  def index
    @status = %w[all pending done].include?(params[:status]) ? params[:status] : 'all'
    if params[:start_date].blank? && params[:end_date].blank?
      # 預設近 7 天，員工不用每天自己調日期
      @start_date = 6.days.ago.to_date
      @end_date   = Date.today
    else
      @start_date = parse_date(params[:start_date])
      @end_date   = parse_date(params[:end_date]) || @start_date
      @end_date   = @start_date if @start_date && @end_date && @end_date < @start_date
    end

    old_orders = select_old_orders(apply_period(build_scope).to_a)

    @products_by_order = build_products_by_order(old_orders)

    # 只留下訂單中含「首次購買」產品（該系列此前沒買過）的舊客
    follow_up_orders = old_orders.select do |o|
      (@products_by_order[o.order_num] || []).any? { |p| p[:prior_date].nil? }
    end

    @gift_records = OrderGiftRecord.where(order_number: follow_up_orders.map(&:order_num)).index_by(&:order_number)

    pending, done = follow_up_orders.partition { |o| @gift_records[o.order_num]&.follow_up_note.blank? }
    @total_count   = follow_up_orders.size
    @pending_count = pending.size
    @done_count    = done.size

    rows = case @status
           when 'pending' then pending
           when 'done'    then done
           else                follow_up_orders
           end
    @groups = LEVELS.map { |lvl| [lvl, rows.select { |o| o.membership_level_col == lvl }] }
  end
end
