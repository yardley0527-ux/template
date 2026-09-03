# path: app/controllers/kol_candidates_controller.rb
# frozen_string_literal: true

# 業配評估：比起既有的品牌別 KOC 名單（Koc/ReloveKoc/...），這裡多了結構化報價
# 欄位（KolQuoteItem）、帳號數據時間序列（KolMetricSnapshot，未來可接 Apify）、
# 以及聲量/口碑查核（KolBuzzCheck，目前由 Claude 用 WebSearch 手動查完寫入）。
class KolCandidatesController < ApplicationController
  before_action :set_candidate, only: %i[show edit update destroy refresh_ig_metrics]

  def index
    @candidates = KolCandidate.order(created_at: :desc)
    @candidates = @candidates.where(status: params[:status]) if params[:status].present?
    @status_counts = KolCandidate.group(:status).count
  end

  def show; end

  def new
    @candidate = KolCandidate.new
    3.times { @candidate.kol_quote_items.build }
  end

  def edit
    @candidate.kol_quote_items.build if @candidate.kol_quote_items.empty?
  end

  def create
    @candidate = KolCandidate.new(candidate_params)

    if @candidate.save
      redirect_to @candidate, notice: "已新增候選人 #{@candidate.name}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @candidate.update(candidate_params)
      redirect_to @candidate, notice: "已更新 #{@candidate.name}"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return head :forbidden unless current_user.admin?

    @candidate.destroy
    redirect_to kol_candidates_path, notice: "已刪除 #{@candidate.name}"
  end

  def refresh_ig_metrics
    if KolIgMetricsFetcher.fetch(@candidate)
      redirect_to @candidate, notice: "已透過 Apify 更新 #{@candidate.name} 的 IG 數據"
    else
      redirect_to @candidate, alert: "查詢失敗（可能是帳號打錯、Apify token 沒設定，或這個人沒填 Instagram 帳號）"
    end
  end

  private

  def set_candidate
    @candidate = KolCandidate.find(params[:id])
  end

  def candidate_params
    params.require(:kol_candidate).permit(
      :name, :campaign, :status, :instagram_handle, :tiktok_handle, :youtube_handle,
      :bio, :content_tags, :contact_email, :contact_line_id, :notes,
      kol_quote_items_attributes: %i[id item_name amount tax_included period notes _destroy]
    )
  end
end
