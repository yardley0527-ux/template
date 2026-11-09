# IG 私訊整理結果：高風險回覆、不適回報、說法矛盾、溝通做法與歷史吃法。內容含客人健康資料，預設只有 admin 能看。
class IgReviewsController < ApplicationController
  def index
    @kind = params[:kind].presence_in(IgReviewItem::KINDS.keys) || "risk"
    @status = params[:status].presence_in(IgReviewItem::STATUSES.keys)
    @q = params[:q].to_s.strip
    @kind_counts = IgReviewItem.group(:kind).count
    @open_counts = IgReviewItem.where(status: "open").group(:kind).count

    scope = IgReviewItem.where(kind: @kind)
    scope = scope.where(status: @status) if @status
    if @q.present?
      term = "%#{IgReviewItem.sanitize_sql_like(@q)}%"
      scope = scope.where("title ILIKE :t OR customer_name ILIKE :t OR customer_email ILIKE :t OR detail::text ILIKE :t OR array_to_string(event_codes, ' ') ILIKE :t", t: term)
    end
    @items = scope.to_a.sort_by { |i| [i.severity_rank, -(i.as_of&.jd || 0), i.id] }
  end

  def update
    item = IgReviewItem.find(params[:id])
    item.update!(status: params[:status].presence_in(IgReviewItem::STATUSES.keys) || item.status,
                 note: params[:note].to_s.strip.presence,
                 handled_by_user_id: current_user.id, handled_at: Time.current)
    redirect_to ig_reviews_path(kind: item.kind, status: params[:filter_status].presence, q: params[:q].presence), notice: "已更新"
  end
end
