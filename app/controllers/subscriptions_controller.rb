class SubscriptionsController < ApplicationController
  before_action :set_subscription, only: [:show, :edit, :update, :destroy, :advance]

  def index
    @subscriptions = Subscription.includes(:shopline_customer)
                                 .order(next_due_on: :asc)

    # filters
    @filter_status  = params[:status].presence
    @filter_series  = params[:series].presence
    @filter_freq    = params[:frequency_days].presence

    @subscriptions = @subscriptions.where(status: @filter_status) if @filter_status
    @subscriptions = @subscriptions.where(product_series: @filter_series) if @filter_series
    @subscriptions = @subscriptions.where(frequency_days: @filter_freq) if @filter_freq

    # dashboard stats
    all_active = Subscription.active
    @stat_active        = all_active.count
    @stat_due_week      = all_active.where(next_due_on: ..Date.today + 7).count
    @stat_due_fortnight = all_active.where(next_due_on: (Date.today + 8)..(Date.today + 14)).count
    @stat_monthly_rev   = all_active.sum { |s| (s.frequency_days == 30 ? 1 : (30.0 / s.frequency_days)) * s.total_per_delivery }.round
    @stat_total         = Subscription.count
  end

  def show; end

  def new
    @subscription = Subscription.new(
      frequency_days: 30,
      quantity: 1,
      min_periods: 3,
      started_on: Date.today,
      next_due_on: Date.today + 30
    )
    @subscription.discount_rate = Subscription::DISCOUNT_FOR_FREQUENCY[30]
    load_customer_options
  end

  def create
    @subscription = Subscription.new(subscription_params)
    @subscription.discount_rate = Subscription::DISCOUNT_FOR_FREQUENCY[@subscription.frequency_days.to_i] if @subscription.discount_rate.blank?
    @subscription.next_due_on   = @subscription.started_on + @subscription.frequency_days if @subscription.started_on && @subscription.frequency_days

    if @subscription.save
      redirect_to subscriptions_path, notice: "定期購已建立。"
    else
      load_customer_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_customer_options
  end

  def update
    if @subscription.update(subscription_params)
      redirect_to subscription_path(@subscription), notice: "已更新。"
    else
      load_customer_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @subscription.update!(status: "cancelled")
    redirect_to subscriptions_path, notice: "已取消定期購。"
  end

  # Mark one delivery as fulfilled and advance next_due_on
  def advance
    @subscription.advance_period!
    redirect_to subscription_path(@subscription), notice: "已完成第 #{@subscription.completed_periods} 期，下次補貨日更新為 #{@subscription.next_due_on.strftime('%Y/%m/%d')}。"
  end

  private

  def set_subscription
    @subscription = Subscription.find(params[:id])
  end

  def load_customer_options
    @customers = ShoplineCustomer.where(membership_level: %w[黑卡 金卡])
                                 .order(:full_name)
                                 .select(:id, :full_name, :email, :mobile_phone, :membership_level)
  end

  def subscription_params
    params.require(:subscription).permit(
      :shopline_customer_id, :product_name, :product_series,
      :frequency_days, :discount_rate, :unit_price, :quantity,
      :status, :started_on, :next_due_on,
      :completed_periods, :min_periods, :notes
    )
  end
end
