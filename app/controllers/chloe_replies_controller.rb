# frozen_string_literal: true

# Chloe 回覆助手：員工貼上客人問題，用 Chloe 回答過的內容組成回覆（附原文依據）。
# 每個人只看到自己問過的；所有人的紀錄在 ChloeReplyLogsController（給老闆檢視）。不會發訊息給客人。
class ChloeRepliesController < ApplicationController
  PER_PAGE = 50

  def index
    scope = ReplyDraft.where(created_by_user_id: current_user.id).recent
    @total = scope.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @drafts = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @refreshing = scope.where(status: "generating").exists?
    @approved_count = ReplyKnowledgeItem.approved.count
    @faq_count = Faq.where.not(answer: [nil, ""]).count
  end

  def create
    question = params[:question].to_s.strip
    return redirect_to(chloe_replies_path, alert: "請先貼上客人的問題") if question.blank?

    draft = ReplyDraft.create!(question: question, created_by_user_id: current_user.id)
    ReplyDraftJob.perform_later(draft.id)
    redirect_to chloe_replies_path, notice: "正在準備回覆，頁面會自動更新"
  end

  # 核准（可修改內容）或不採用。修改過或原本是草稿的答案才存成新知識，引用舊答案不重複存。
  # 只能處理自己問的；admin 可以處理任何人的。
  def update
    draft = editable_drafts.find_by(id: params[:id])
    return redirect_to(chloe_replies_path, alert: "只能處理自己問的題目") unless draft
    return redirect_to(chloe_replies_path, alert: "這則不是待核准狀態") unless draft.status == "pending"

    if params[:decision] == "reject"
      draft.update!(status: "rejected", reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      return redirect_to(chloe_replies_path, notice: "已標記不採用")
    end

    final = params[:final_answer].to_s.strip
    return redirect_to(chloe_replies_path, alert: "答案不能空白") if final.blank?

    ActiveRecord::Base.transaction do
      draft.update!(status: "approved", final_answer: final, reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      unless draft.match_ref.present? && final == draft.answer
        ReplyKnowledgeItem.create!(question: draft.question, answer: final, source: "chloe", status: "approved",
                                   reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      end
    end
    redirect_to chloe_replies_path, notice: "已核准並存入知識庫"
  end

  private

  def editable_drafts
    current_user.admin? ? ReplyDraft.all : ReplyDraft.where(created_by_user_id: current_user.id)
  end
end
