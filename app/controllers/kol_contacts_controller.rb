class KolContactsController < ApplicationController
  PER_PAGE = 10
  LOGISTICS_USERNAME = "crmdata".freeze

  helper_method :can_edit_logistics_fields?, :can_edit_social_fields?

  def index
    @message_template = KolMessageTemplate.current

    @contacts = KolContact.ordered
    @contacts = @contacts.where(status: params[:status]) if params[:status].present?

    @total_count = KolContact.count
    @status_counts = KolContact.group(:status).count

    @page = [params[:page].to_i, 1].max
    @total_pages = [(@contacts.count.to_f / PER_PAGE).ceil, 1].max
    @page = @total_pages if @page > @total_pages
    @contacts = @contacts.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def update_message_template
    KolMessageTemplate.current.update(content: params[:content])
    redirect_to kol_contacts_path, notice: "已更新發送訊息內容"
  end

  def create
    @contact = KolContact.new(contact_params)
    @contact.source = "手動新增"

    if @contact.save
      redirect_to kol_contacts_path, notice: "已新增 #{@contact.ig_username}"
    else
      redirect_to kol_contacts_path, alert: @contact.errors.full_messages.join("、")
    end
  end

  def update
    @contact = KolContact.find(params[:id])
    @contact.update(contact_params)
    redirect_back fallback_location: kol_contacts_path, allow_other_host: false, notice: "已更新 #{@contact.ig_username}"
  end

  def destroy
    return head :forbidden unless current_user.admin?

    @contact = KolContact.find(params[:id])
    @contact.destroy
    redirect_to kol_contacts_path, notice: "已刪除 #{@contact.ig_username}"
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

  def contact_params
    permitted = can_edit_social_fields? ? %i[ig_username ig_full_name alias email profile_url status notes follows_chloe_ig follows_official_ig email_sent] : []
    permitted += %i[logistics_notes pr_gift_shipped_at] if can_edit_logistics_fields?

    params.require(:kol_contact).permit(*permitted)
  end
end
