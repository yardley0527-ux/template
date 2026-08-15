class KoreanBrandLeadsController < ApplicationController
  def index
    @korean_brand_leads = KoreanBrandLead.ordered
  end

  def create
    @korean_brand_lead = KoreanBrandLead.new(korean_brand_lead_params)

    if @korean_brand_lead.save
      redirect_to korean_brand_leads_path, notice: "已新增 #{@korean_brand_lead.product_name}"
    else
      redirect_to korean_brand_leads_path, alert: @korean_brand_lead.errors.full_messages.join("、")
    end
  end

  def update
    @korean_brand_lead = KoreanBrandLead.find(params[:id])

    if @korean_brand_lead.update(korean_brand_lead_params)
      redirect_to korean_brand_leads_path, notice: "已更新 #{@korean_brand_lead.product_name}"
    else
      redirect_to korean_brand_leads_path, alert: @korean_brand_lead.errors.full_messages.join("、")
    end
  end

  def destroy
    @korean_brand_lead = KoreanBrandLead.find(params[:id])
    @korean_brand_lead.destroy
    redirect_to korean_brand_leads_path, notice: "已刪除 #{@korean_brand_lead.product_name}"
  end

  private

  def korean_brand_lead_params
    params.require(:korean_brand_lead).permit(
      :product_name, :source_url, :contact_channel, :contacted, :contacted_at,
      :email_content, :replied, :notes, :follow_up
    )
  end
end
