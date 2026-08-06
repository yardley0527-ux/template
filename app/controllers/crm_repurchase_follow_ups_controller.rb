# frozen_string_literal: true

# 回購追蹤 Dashboard（Phase 2）。權限沿用既有 ApplicationController#authorize_page!
# （PagePermission 依 controller_name 授權，admin 全開）——不自行發明角色。
class CrmRepurchaseFollowUpsController < ApplicationController
  before_action :set_cycle, only: :update

  def index
    @query   = CrmRepurchaseDashboardQuery.new(dashboard_filter_params)
    @kpis    = @query.kpis
    @cycles  = @query.cycles.to_a
    @page        = @query.page
    @total_pages = @query.total_pages
    @total_count = @query.total_count

    @customers_by_email = load_customers_for(@cycles)

    @product_options  = CrmProduct.confirmed
      .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
      .order(:id).pluck(:label, :key)
    @product_labels_by_key = @product_options.to_h { |label, key| [key, label] }
    @assignee_options = User.order(:username).pluck(:username, :id)
    @status_options    = CrmCustomerProductCycle::ALL_DASHBOARD_STATUSES
  end

  def update
    CrmCustomerProductCycleFollowUpService.call(
      cycle:                @cycle,
      actor:                current_user,
      action:               follow_up_params[:follow_up_action],
      note:                 follow_up_params[:note],
      next_contact_date:    follow_up_params[:next_contact_date],
      remaining_days:       follow_up_params[:remaining_days],
      assigned_to_user_id:  follow_up_params[:assigned_to_user_id]
    )
    redirect_back fallback_location: crm_repurchase_dashboard_path, notice: "已更新"
  rescue CrmCustomerProductCycleFollowUpService::InvalidActionError => e
    redirect_back fallback_location: crm_repurchase_dashboard_path, alert: e.message
  end

  private

  def set_cycle
    @cycle = CrmCustomerProductCycle.find(params[:id])
  end

  def follow_up_params
    params.require(:follow_up).permit(
      :follow_up_action, :note, :next_contact_date, :remaining_days, :assigned_to_user_id
    )
  end

  def dashboard_filter_params
    params.permit(:product_key, :status, :assigned_to, :q, :page)
  end

  # 只針對目前這一頁的 email 批次查 ShoplineCustomer，不是每列各查一次——
  # 分頁後最多 PER_PAGE 筆，一次 IN 查詢就夠，避免 N+1。
  def load_customers_for(cycles)
    emails = cycles.map(&:email).uniq
    return {} if emails.empty?

    ShoplineCustomer.where(email: emails)
      .select(:email, :full_name, :membership_level, :mobile_phone)
      .index_by(&:email)
  end
end
