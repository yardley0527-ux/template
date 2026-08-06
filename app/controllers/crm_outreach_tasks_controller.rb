# frozen_string_literal: true

# 「我的今日任務」：管理者看全部，一般使用者只看分派給自己的任務——這裡的
# 「管理者」判斷跟 CrmLivestreamSchedulesController 用同一個
# current_user.admin?，不新增角色。操作沿用 Phase 2 的
# CrmCustomerProductCycleFollowUpService（透過 CrmLivestreamOutreachTaskFollowUpService
# 包一層），不建立第二套聯絡紀錄。
class CrmOutreachTasksController < ApplicationController
  PER_PAGE = 30

  before_action :set_task, only: %i[update reschedule]
  before_action :authorize_task_access!, only: %i[update reschedule]
  before_action :require_admin!, only: :reschedule
  before_action :set_paper_trail_whodunnit, only: :reschedule

  def index
    @bucket = params[:bucket].presence_in(%w[today overdue upcoming completed all_pending]) || "today"
    @page   = [params[:page].to_i, 1].max

    scope = visible_scope
    scope = scope.where(assigned_to_user_id: params[:assigned_to]) if params[:assigned_to].present? && current_user.admin?

    today = Date.current
    scope = case @bucket
      when "overdue"     then scope.overdue_as_of(today)
      when "upcoming"     then scope.upcoming_as_of(today)
      when "completed"    then scope.completed_tasks
      when "all_pending"  then scope.pending_tasks
      else scope.pending_tasks.on_date(today)
      end

    @total       = scope.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page        = [@page, @total_pages].min

    @tasks = scope
      .includes(:livestream, :assigned_to, cycle: :assigned_to)
      .order(:scheduled_date, :id)
      .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    @customers_by_email = load_customers_for(@tasks)
    @product_labels_by_key = CrmProduct.confirmed.pluck(:key, :label).to_h
    @assignee_options = User.order(:username).pluck(:username, :id) if current_user.admin?
  end

  def update
    CrmLivestreamOutreachTaskFollowUpService.call(
      task:               @task,
      actor:              current_user,
      action:             follow_up_params[:follow_up_action],
      note:               follow_up_params[:note],
      next_contact_date:  follow_up_params[:next_contact_date],
      remaining_days:     follow_up_params[:remaining_days]
    )
    redirect_back fallback_location: crm_outreach_tasks_path, notice: "已更新"
  rescue CrmCustomerProductCycleFollowUpService::InvalidActionError => e
    redirect_back fallback_location: crm_outreach_tasks_path, alert: e.message
  end

  def reschedule
    CrmLivestreamOutreachScheduler.reschedule!(
      task: @task, new_date: reschedule_params[:scheduled_date],
      new_assigned_to_user_id: reschedule_params[:assigned_to_user_id]
    )
    redirect_back fallback_location: crm_outreach_tasks_path, notice: "已重新排程"
  rescue CrmLivestreamOutreachScheduler::InvalidScheduleError, ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: crm_outreach_tasks_path, alert: e.message
  end

  private

  def set_task
    @task = CrmLivestreamOutreachTask.find(params[:id])
  end

  # 客服只能操作分派給自己的任務；管理者不受限。
  def authorize_task_access!
    return if current_user&.admin?
    return if @task.assigned_to_user_id == current_user&.id

    head :forbidden
  end

  def require_admin!
    head :forbidden unless current_user&.admin?
  end

  def visible_scope
    current_user.admin? ? CrmLivestreamOutreachTask.all : CrmLivestreamOutreachTask.for_user(current_user)
  end

  def follow_up_params
    params.require(:follow_up).permit(:follow_up_action, :note, :next_contact_date, :remaining_days)
  end

  def reschedule_params
    params.permit(:scheduled_date, :assigned_to_user_id)
  end

  def load_customers_for(tasks)
    emails = tasks.map { |t| t.cycle.email }.uniq
    return {} if emails.empty?

    ShoplineCustomer.where(email: emails)
      .select(:email, :full_name, :membership_level, :mobile_phone)
      .index_by(&:email)
  end
end
