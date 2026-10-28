# 行銷機會頁：資料狀態、近期互動者、產品互動機會、回購機會、來源表現、AI 建議。
# 客群都由 Marketing::Segments 依白名單參數計算；AI 建議手動觸發、背景產生。
class MarketingOpportunitiesController < ApplicationController
  TABS = {
    "interactors" => "近期互動者", "products" => "產品互動機會", "repurchase" => "回購機會",
    "sources" => "來源表現", "ai" => "AI 建議"
  }.freeze

  def index
    @tab = params[:tab].presence_in(TABS.keys) || "interactors"
    @status = Marketing::DataStatus.new
    @segments = Marketing::Segments.new
    send("load_#{@tab}")
  rescue ArgumentError, Date::Error => e
    redirect_to marketing_opportunities_path(tab: @tab), alert: e.message
  end

  # 單一客群的完整名單
  def segment
    @result = Marketing::Segments.new.build(params[:key].to_s, params.fetch(:filter, {}).permit!.to_h)
  rescue ArgumentError, KeyError => e
    redirect_to marketing_opportunities_path, alert: e.message
  end

  def suggest
    suggestion = MarketingAiSuggestion.request!(user: current_user)
    notice = suggestion.created_at > 5.seconds.ago ? "已開始產生 AI 建議，約一兩分鐘後重新整理" : "已經有一份 AI 建議正在產生，請稍候"
    redirect_to marketing_opportunities_path(tab: "ai"), notice: notice
  end

  private

  def load_interactors
    @params = Marketing::Segments.normalize_params("recent_interactors", params.permit(:days, :source, :tag, :identity).to_h)
    @result = @segments.build("recent_interactors", @params)
    @tags = ManychatSubscriber.where.not(tags: []).pluck(:tags).flatten.uniq.sort
    @source_options = source_options
  end

  def load_products
    @products = CrmProduct.where(status: "confirmed", include_in_analysis: true).order(:key)
    @days = Marketing::Segments::DAYS.include?(params[:days].to_i) ? params[:days].to_i : 14
    mapped = ManychatSource.where(active: true).pluck(:product_keys).flatten.uniq
    @rows = @products.map do |p|
      interest = (@segments.build("product_source_interest", "product_key" => p.key, "days" => @days) if mapped.include?(p.key))
      request = @segments.build("product_explicit_request", "product_key" => p.key, "days" => @days)
      { product: p, mapped: mapped.include?(p.key), interest: interest, request: request }
    end
  end

  def load_repurchase
    @params = Marketing::Segments.normalize_params("repurchase_due", params.permit(:product_key, :ahead).to_h)
    @all = @segments.build("repurchase_due", @params)
    @with_manychat = @segments.build("repurchase_due", @params.merge("manychat_only" => true))
    @products = CrmProduct.where(status: "confirmed", include_in_analysis: true).order(:key)
  end

  def load_sources
    @to = params[:to].present? ? Date.parse(params[:to]) : Date.current
    @from = params[:from].present? ? Date.parse(params[:from]) : @to - 29
    @perf = Marketing::SourcePerformance.new(from: @from, to: @to)
  end

  def load_ai
    @suggestion = MarketingAiSuggestion.order(:created_at).last
    @history = MarketingAiSuggestion.order(created_at: :desc).limit(10)
  end

  def source_options
    raw = ManychatInteraction.where("interacted_at > ?", 60.days.ago).distinct.pluck(:source)
    mapped = ManychatSource.index_by_raw_name
    configured = ManychatSource.order(:name).map { |s| [s.name, s.key] }
    configured + raw.reject { |r| mapped.key?(r) }.sort.map { |r| ["#{r.presence || Manychat::LeadReport::NO_SOURCE}（未設定）", r.presence || Manychat::LeadReport::NO_SOURCE] }
  end
end
