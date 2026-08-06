# frozen_string_literal: true

# 直播回購候選名單（Phase 3）。權限沿用既有 ApplicationController#authorize_page!，
# 不自行發明角色。操作沿用 Phase 2 的 CrmCustomerProductCycleFollowUpService，
# 不建立第二套聯絡紀錄，只多傳一個 livestream_id。
class LivestreamRepurchaseCandidatesController < ApplicationController
  before_action :set_livestream_and_cycle, only: :update

  def index
    @livestreams = Livestream.where("array_length(product_keys, 1) > 0").order(date: :desc).limit(100)
    @livestream  = Livestream.find_by(id: params[:livestream_id]) if params[:livestream_id].present?

    return unless @livestream

    @query       = LivestreamRepurchaseCandidateQuery.new(@livestream, candidate_filter_params)
    @kpis        = @query.kpis
    @summary     = @query.summary_counts
    @rows        = @query.page_rows
    @page        = @query.page
    @total_pages = @query.total_pages
    @total_count = @query.total_count
    @products_missing_cycle_config = @query.products_missing_cycle_config
    @historical  = @query.historical?

    @customers_by_email    = load_customers_for(@rows)
    @product_labels_by_key = CrmProduct.where(key: @livestream.product_keys).pluck(:key, :label).to_h
    @assignee_options       = User.order(:username).pluck(:username, :id)
    @status_options         = CrmCustomerProductCycle::ALL_DASHBOARD_STATUSES
  end

  def update
    CrmCustomerProductCycleFollowUpService.call(
      cycle:                @cycle,
      actor:                current_user,
      action:               follow_up_params[:follow_up_action],
      note:                 follow_up_params[:note],
      next_contact_date:    follow_up_params[:next_contact_date],
      remaining_days:       follow_up_params[:remaining_days],
      assigned_to_user_id:  follow_up_params[:assigned_to_user_id],
      livestream_id:        @livestream.id
    )
    redirect_back fallback_location: livestream_repurchase_candidates_path(livestream_id: @livestream.id), notice: "已更新"
  rescue CrmCustomerProductCycleFollowUpService::InvalidActionError => e
    redirect_back fallback_location: livestream_repurchase_candidates_path(livestream_id: @livestream.id), alert: e.message
  end

  private

  def set_livestream_and_cycle
    @livestream = Livestream.find(params[:livestream_id])
    @cycle      = CrmCustomerProductCycle.find(params[:cycle_id])
  end

  def follow_up_params
    params.require(:follow_up).permit(
      :follow_up_action, :note, :next_contact_date, :remaining_days, :assigned_to_user_id
    )
  end

  def candidate_filter_params
    params.permit(:reason, :product_key, :status, :assigned_to, :q, :page, :win_back_max_days)
  end

  def load_customers_for(rows)
    emails = rows.map { |r| r.representative_cycle.email }.uniq
    return {} if emails.empty?

    ShoplineCustomer.where(email: emails)
      .select(:email, :full_name, :membership_level, :mobile_phone)
      .index_by(&:email)
  end
end
