# 活動草稿：從客群或 AI 建議卡建立，保存條件、名單快照、商品、優惠引用、文案、管道與時間。
# 建立草稿不代表已發送；第一版不發送、不回寫標籤。
class MarketingCampaignDraftsController < ApplicationController
  before_action :load_draft, only: [:show, :edit, :update]

  def index
    @drafts = MarketingCampaignDraft.includes(:created_by).order(created_at: :desc).limit(100)
  end

  def show
    @members = @draft.members.order(:id).limit(500)
  end

  def create
    suggestion = MarketingAiSuggestion.find(params[:suggestion_id]) if params[:suggestion_id].present?
    key, seg_params, index = from_request(suggestion)
    draft = MarketingCampaignDraft.create_from_segment!(segment_key: key, segment_params: seg_params, user: current_user,
                                                       suggestion: suggestion, card_index: index)
    redirect_to edit_marketing_campaign_draft_path(draft), notice: "已建立草稿，名單 #{draft.member_count} 人（尚未發送）"
  rescue ArgumentError, KeyError, ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: marketing_opportunities_path, alert: "無法建立草稿：#{e.message}"
  end

  def edit; end

  def update
    if @draft.update(draft_params)
      redirect_to marketing_campaign_draft_path(@draft), notice: "已儲存草稿"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load_draft
    @draft = MarketingCampaignDraft.find(params[:id])
  end

  # AI 卡：客群條件取自當時的分析快照，不接受 AI 或表單另外帶的條件
  def from_request(suggestion)
    if suggestion
      index = Integer(params[:card_index])
      card = suggestion.cards.fetch(index)
      segment = suggestion.segment(card["segment_id"]) or raise ArgumentError, "這張建議卡沒有指定客群，請改從客群建立"
      [segment["key"], segment["params"], index]
    else
      [params.require(:segment_key), params.fetch(:segment_params, {}).permit!.to_h, nil]
    end
  end

  def draft_params
    params.require(:marketing_campaign_draft).permit(:name, :goal, :status, :copy_text, :planned_channel, :planned_start_on,
                                                     :planned_end_on, :success_metric, :promotion_snapshot_id, product_keys: [])
  end
end
