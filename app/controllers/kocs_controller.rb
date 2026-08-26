class KocsController < ApplicationController
  PER_PAGE = 10
  LOGISTICS_USERNAME = "crmdata".freeze

  helper_method :can_edit_logistics_fields?, :can_edit_social_fields?

  def index
    @message_template = KocMessageTemplate.current

    @sort = params[:sort]
    @kocs = @sort == "likes" ? Koc.order(Arel.sql("COALESCE(max_likes, 0) DESC")) : Koc.ordered_by_engagement

    @kocs = @kocs.where(status: params[:status]) if params[:status].present?
    @kocs = @kocs.where(has_paid_partnership: true) if params[:paid] == "1"

    @total_count  = Koc.count
    @paid_count   = Koc.where(has_paid_partnership: true).count
    @status_counts = Koc.group(:status).count

    @page = [params[:page].to_i, 1].max
    @total_pages = [(@kocs.count.to_f / PER_PAGE).ceil, 1].max
    @page = @total_pages if @page > @total_pages
    @kocs = @kocs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def update_message_template
    KocMessageTemplate.current.update(content: params[:content])
    redirect_to kocs_path, notice: "已更新發送訊息內容"
  end

  def create
    return head :forbidden unless current_user.admin?

    @koc = Koc.new(koc_params)
    @koc.source = "手動新增"

    if @koc.save
      redirect_to kocs_path, notice: "已新增 #{@koc.ig_username}"
    else
      redirect_to kocs_path, alert: @koc.errors.full_messages.join("、")
    end
  end

  def update
    @koc = Koc.find(params[:id])
    @koc.update(koc_params)
    redirect_back fallback_location: kocs_path, allow_other_host: false, notice: "已更新 #{@koc.ig_username}"
  end

  def destroy
    return head :forbidden unless current_user.admin?

    @koc = Koc.find(params[:id])
    @koc.destroy
    redirect_to kocs_path, notice: "已刪除 #{@koc.ig_username}"
  end

  private

  # 物流部備註／公關品寄出日期只有 crmdata 帳號（物流部）能編輯，admin 維持全權限。
  def can_edit_logistics_fields?
    current_user.admin? || current_user.username == LOGISTICS_USERNAME
  end

  # crmdata（物流部）只能編輯物流部備註／公關品寄出日期，其他欄位（含社群聯絡備註、
  # 接洽狀態、拍影片狀態、Chloe IG／官方 IG／Email 追蹤）一律不能碰。
  def can_edit_social_fields?
    current_user.username != LOGISTICS_USERNAME
  end

  # 社群部帳號能更新接洽狀態、拍影片狀態、Chloe IG／官方 IG 追蹤、聯絡備註，新增/刪除維持 admin 專用。
  def koc_params
    permitted = if current_user.admin?
      %i[ig_username ig_full_name alias email profile_url status notes video_shoot_status follows_chloe_ig follows_official_ig email_sent]
    elsif can_edit_social_fields?
      %i[status notes video_shoot_status follows_chloe_ig follows_official_ig email_sent]
    else
      []
    end
    permitted += %i[logistics_notes pr_gift_shipped_at] if can_edit_logistics_fields?

    params.require(:koc).permit(*permitted)
  end
end
