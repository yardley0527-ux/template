class ReloveKocsController < ApplicationController
  PER_PAGE = 10
  LOGISTICS_USERNAME = "crmdata".freeze

  helper_method :can_edit_logistics_fields?, :can_edit_social_fields?

  def index
    @sort = params[:sort]
    @kocs = @sort == "likes" ? ReloveKoc.order(Arel.sql("COALESCE(max_likes, 0) DESC")) : ReloveKoc.ordered_by_engagement
    @kocs = @kocs.where(status: params[:status]) if params[:status].present?
    @kocs = @kocs.where(has_paid_partnership: true) if params[:paid] == "1"
    @kocs = @kocs.where("email ILIKE ?", "%#{params[:email].to_s.strip}%") if params[:email].present?

    @total_count = ReloveKoc.count
    @paid_count  = ReloveKoc.where(has_paid_partnership: true).count
    @status_counts = ReloveKoc.group(:status).count

    @page = [params[:page].to_i, 1].max
    @total_pages = [(@kocs.count.to_f / PER_PAGE).ceil, 1].max
    @page = @total_pages if @page > @total_pages
    @kocs = @kocs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def create
    @koc = ReloveKoc.new(koc_params)
    @koc.source = "手動新增"

    if @koc.save
      redirect_to relove_kocs_path, notice: "已新增 #{@koc.ig_username}"
    else
      redirect_to relove_kocs_path, alert: @koc.errors.full_messages.join("、")
    end
  end

  def update
    @koc = ReloveKoc.find(params[:id])
    @koc.update(koc_params)
    redirect_back fallback_location: relove_kocs_path, allow_other_host: false, notice: "已更新 #{@koc.ig_username}"
  end

  def destroy
    return head :forbidden unless current_user.admin? || current_user.role&.key == "social"

    @koc = ReloveKoc.find(params[:id])
    @koc.destroy
    redirect_to relove_kocs_path, notice: "已刪除 #{@koc.ig_username}"
  end

  private

  # 物流部備註／公關品寄出日期只有 crmdata 帳號（物流部）能編輯，admin 維持全權限。
  def can_edit_logistics_fields?
    current_user.admin? || current_user.username == LOGISTICS_USERNAME
  end

  # crmdata（物流部）只能編輯物流部備註／公關品寄出日期，其他欄位一律不能碰。
  def can_edit_social_fields?
    current_user.username != LOGISTICS_USERNAME
  end

  def koc_params
    permitted = can_edit_social_fields? ? %i[ig_username ig_full_name alias email profile_url status notes follows_chloe_ig follows_official_ig video_shoot_status email_sent] : []
    permitted += %i[logistics_notes pr_gift_shipped_at] if can_edit_logistics_fields?

    params.require(:relove_koc).permit(*permitted)
  end
end
