# IG 私訊整理結果（只供查詢）：需修正的說法、不適紀錄、說法不一致、溝通做法與歷史吃法。內容含客人健康資料，預設只有 admin 能看。
class IgReviewsController < ApplicationController
  def index
    @kind = params[:kind].presence_in(IgReviewItem::KINDS.keys) || "risk"
    @q = params[:q].to_s.strip
    @kind_counts = IgReviewItem.group(:kind).count

    scope = IgReviewItem.where(kind: @kind)
    if @q.present?
      term = "%#{IgReviewItem.sanitize_sql_like(@q)}%"
      scope = scope.where("title ILIKE :t OR customer_name ILIKE :t OR customer_email ILIKE :t OR detail::text ILIKE :t OR array_to_string(event_codes, ' ') ILIKE :t", t: term)
    end
    @items = scope.to_a.sort_by { |i| [i.severity_rank, -(i.as_of&.jd || 0), i.id] }
  end
end
