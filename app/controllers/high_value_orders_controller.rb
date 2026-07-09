class HighValueOrdersController < ApplicationController
  include HighValueOrderScoping

  THRESHOLD = HighValueOrderScoping::THRESHOLD
  LEVELS    = HighValueOrderScoping::LEVELS

  def index
    @series_options = CrmProduct.series_labels_for_filter
    @period         = params[:period].presence || 'month'
    @tab            = %w[new old].include?(params[:tab]) ? params[:tab] : 'old'
    @series_filter  = params[:series_filter].presence
    if params[:start_date].blank? && params[:end_date].blank?
      @start_date = @end_date = Date.yesterday
    else
      @start_date = parse_date(params[:start_date])
      @end_date   = parse_date(params[:end_date]) || @start_date
      @end_date   = @start_date if @start_date && @end_date && @end_date < @start_date
    end

    all_orders = apply_period(build_scope).to_a

    new_orders = all_orders.select { |o| o.purchase_count_val.to_i == 1 }
    old_orders = select_old_orders(all_orders)

    @new_count  = new_orders.size
    @old_count  = old_orders.size
    @tab_counts = LEVELS.index_with { |lvl| old_orders.count { |o| o.membership_level_col == lvl } }

    @groups = @tab == 'new' ? [["新客", new_orders]] : LEVELS.map { |lvl| [lvl, old_orders.select { |o| o.membership_level_col == lvl }] }

    visible_orders = @groups.flat_map { |_, rows| rows }
    order_nums = visible_orders.map(&:order_num)
    @gift_records = OrderGiftRecord.where(order_number: order_nums).index_by(&:order_number)

    customer_ids = visible_orders.map(&:shopline_customer_id).compact
    @profiles_by_customer_id = CustomerProfile.where(shopline_customer_id: customer_ids).index_by(&:shopline_customer_id)

    @products_by_order = build_products_by_order(visible_orders)

    if @tab == 'new'
      @health_missing_count = new_orders.count do |o|
        profile = @profiles_by_customer_id[o.shopline_customer_id]
        profile&.health_profile.blank? && profile&.health_tags.blank?
      end
    else
      @old_health_missing_count = old_orders.count do |o|
        profile = @profiles_by_customer_id[o.shopline_customer_id]
        profile&.health_profile.blank? && profile&.health_tags.blank?
      end
    end
  end
end
