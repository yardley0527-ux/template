# frozen_string_literal: true

# 建立/預覽直播客服排程（Phase 4）。頁面權限沿用既有 authorize_page!；
# 「只有具備現有管理權限者能建立及重新安排排程」這裡用既有的
# current_user.admin? 判斷——這是這個 codebase 目前唯一的管理權限訊號
# （角色系統只有 admin/一般部門角色的區分，沒有另一層「主管」角色），
# 不自行發明新角色。
class CrmLivestreamSchedulesController < ApplicationController
  before_action :set_livestream
  before_action :require_admin!

  def new
    @assignee_options = User.order(:username).pluck(:username, :id)
    @default_start_date = CrmLivestreamOutreachScheduler.default_start_date(@livestream)
    @default_end_date   = CrmLivestreamOutreachScheduler.default_end_date(@livestream)
    @livestream_already_past = @livestream.date < Date.current
  end

  # 預覽：純計算，不寫 DB（CrmLivestreamOutreachScheduler.preview 內部只查詢，見該檔案）。
  def preview
    @plan = CrmLivestreamOutreachScheduler.preview(**scheduler_args)
    render_form_with_current_values
  rescue CrmLivestreamOutreachScheduler::InvalidScheduleError => e
    flash.now[:alert] = e.message
    render_form_with_current_values
  end

  # 確認後才建立任務：重新跑一次一樣的 deterministic 計算（不是信任前一個
  # request 的預覽結果），寫入 DB。
  def create
    @plan = CrmLivestreamOutreachScheduler.commit!(actor: current_user, **scheduler_args)
    redirect_to livestream_repurchase_candidates_path(livestream_id: @livestream.id),
      notice: "已建立 #{@plan.scheduled_count} 筆排程任務" \
              "#{@plan.unscheduled_count.positive? ? "（#{@plan.unscheduled_count} 人因產能不足未安排，仍留在候選池）" : ""}"
  rescue CrmLivestreamOutreachScheduler::InvalidScheduleError => e
    redirect_to new_crm_livestream_schedule_path(@livestream), alert: e.message
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:livestream_id])
  end

  def require_admin!
    head :forbidden unless current_user&.admin?
  end

  def render_form_with_current_values
    @assignee_options = User.order(:username).pluck(:username, :id)
    @default_start_date = CrmLivestreamOutreachScheduler.default_start_date(@livestream)
    @default_end_date   = CrmLivestreamOutreachScheduler.default_end_date(@livestream)
    @livestream_already_past = @livestream.date < Date.current
    render :new
  end

  def schedule_form_params
    params.permit(:start_date, :end_date, :daily_cap, :exclude_saturday, :exclude_sunday, :allow_same_day_contact, user_ids: [])
  end

  def scheduler_args
    p = schedule_form_params
    {
      livestream:               @livestream,
      start_date:               Date.parse(p[:start_date]),
      end_date:                  Date.parse(p[:end_date]),
      user_ids:                  Array(p[:user_ids]).reject(&:blank?),
      daily_cap:                 p[:daily_cap],
      exclude_saturday:          p[:exclude_saturday],
      exclude_sunday:            p[:exclude_sunday],
      allow_same_day_contact:    p[:allow_same_day_contact]
    }
  end
end
