# frozen_string_literal: true

class ProductRegistryController < ApplicationController
  PER_PAGE = 20

  before_action :set_paper_trail_whodunnit, only: :update_inventory

  def index
    @inventory_products = CrmProduct.confirmed.includes(:inventory_status_updated_by).order(:id)
    @q      = params[:q].to_s.strip
    @status = params[:status].to_s.strip
    @page   = [params[:page].to_i, 1].max

    scope = ProductNameMapping
      .includes(:crm_product, :suggested_crm_product)
      .order(Arel.sql("CASE mapping_status WHEN 'pending' THEN 0 ELSE 1 END, updated_at DESC"))

    scope = scope.where("raw_name ILIKE ?", "%#{@q}%") if @q.present?
    scope = scope.where(mapping_status: @status)       if @status.present?

    @total       = scope.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page        = [@page, @total_pages].min
    @mappings    = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    @status_options = ProductNameMapping::MAPPING_STATUSES
  end

  # 庫存維護：只開放正式（confirmed）產品；狀態變更一律人工明確操作，
  # 不做任何自動轉換（到貨日過期／actual_restock_date 填入都不改狀態）。
  def update_inventory
    product = CrmProduct.find(params[:id])

    unless product.status == "confirmed"
      redirect_back fallback_location: product_registry_path,
        alert: "只有正式產品可以管理庫存"
      return
    end

    product.assign_attributes(inventory_params)
    product.inventory_status_updated_at    = Time.current
    product.inventory_status_updated_by_id = current_user.id

    if product.save
      redirect_back fallback_location: product_registry_path,
        notice: "已更新「#{product.label}」庫存狀態"
    else
      redirect_back fallback_location: product_registry_path,
        alert: "庫存更新失敗：#{product.errors.full_messages.join('、')}"
    end
  end

  def confirm
    mapping = ProductNameMapping.find(params[:id])

    if mapping.suggested_crm_product_id.blank?
      redirect_back fallback_location: product_registry_path,
        alert: "此筆沒有建議對應產品，無法直接確認"
      return
    end

    mapping.update!(
      crm_product_id:      mapping.suggested_crm_product_id,
      mapping_status:      "confirmed_alias",
      reviewed_at:         Time.current,
      reviewed_by_user_id: current_user.id
    )

    redirect_back fallback_location: product_registry_path,
      notice: "已確認：#{mapping.raw_name}"
  end

  def ignore
    mapping = ProductNameMapping.find(params[:id])
    mapping.update!(
      mapping_status:      "ignored",
      reviewed_at:         Time.current,
      reviewed_by_user_id: current_user.id
    )
    redirect_back fallback_location: product_registry_path,
      notice: "已略過：#{mapping.raw_name}"
  end

  def create_product
    mapping = ProductNameMapping.find(params[:id])
    key     = params[:product_key].to_s.strip
    label   = params[:product_label].to_s.strip

    if key.blank? || label.blank?
      redirect_back fallback_location: product_registry_path,
        alert: "Key 和 Label 不能空白"
      return
    end

    unless key.match?(CrmProduct::KEY_FORMAT)
      redirect_back fallback_location: product_registry_path,
        alert: "Key 格式錯誤（只能英文小寫 + 數字 + 底線，且必須以小寫字母開頭）"
      return
    end

    ActiveRecord::Base.transaction do
      product = CrmProduct.create!(
        key:                 key,
        label:               label,
        status:              "confirmed",
        include_in_analysis: true,
        source:              "manual_review",
        reviewed_at:         Time.current,
        reviewed_by_user_id: current_user.id
      )
      mapping.update!(
        crm_product_id:      product.id,
        mapping_status:      "new_key_needed",
        reviewed_at:         Time.current,
        reviewed_by_user_id: current_user.id
      )
    end

    redirect_back fallback_location: product_registry_path,
      notice: "已建立新產品「#{label}」並指派 #{mapping.raw_name}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: product_registry_path,
      alert: "建立失敗：#{e.record.errors.full_messages.join('、')}"
  rescue ActiveRecord::RecordNotUnique
    redirect_back fallback_location: product_registry_path,
      alert: "Key「#{params[:product_key]}」已存在，請使用其他 key"
  end

  private

  def inventory_params
    params.require(:crm_product).permit(
      :availability_status, :expected_restock_date, :actual_restock_date, :inventory_note
    )
  end
end
