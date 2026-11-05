# Chloe 回覆助手（測試）：貼上客人問題，看已核准答案或 AI 草稿，核准後存進知識庫。不會發訊息給客人。
class ReplyAssistantController < ApplicationController
  def index
    @drafts = ReplyDraft.recent.limit(30)
    @refreshing = @drafts.any? { |d| d.status == "generating" }
    @approved_count = ReplyKnowledgeItem.approved.count
    @faq_count = Faq.where.not(answer: [nil, ""]).count
    @pending_count = ReplyKnowledgeItem.where(status: "pending").count
    @pending_items = ReplyKnowledgeItem.where(status: "pending").order(:id).limit(10)
  end

  def create
    question = params[:question].to_s.strip
    return redirect_to(reply_assistant_index_path, alert: "請先貼上客人的問題") if question.blank?

    draft = ReplyDraft.create!(question: question, created_by_user_id: current_user.id)
    ReplyDraftJob.perform_later(draft.id)
    redirect_to reply_assistant_index_path, notice: "正在準備回覆，頁面會自動更新"
  end

  # 核准（可修改內容）或不採用。修改過或原本是草稿的答案才存成新知識，引用舊答案不重複存。
  def update
    draft = ReplyDraft.find(params[:id])
    return redirect_to(reply_assistant_index_path, alert: "這則不是待核准狀態") unless draft.status == "pending"

    if params[:decision] == "reject"
      draft.update!(status: "rejected", reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      return redirect_to(reply_assistant_index_path, notice: "已標記不採用")
    end

    final = params[:final_answer].to_s.strip
    return redirect_to(reply_assistant_index_path, alert: "答案不能空白") if final.blank?

    ActiveRecord::Base.transaction do
      draft.update!(status: "approved", final_answer: final, reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      unless draft.match_ref.present? && final == draft.answer
        ReplyKnowledgeItem.create!(question: draft.question, answer: final, source: "chloe", status: "approved",
                                   reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      end
    end
    redirect_to reply_assistant_index_path, notice: "已核准並存入知識庫"
  end

  # 歷史問答：核准後機器人才會使用，可先修改問題和答案。
  def review_item
    item = ReplyKnowledgeItem.find(params[:id])
    return redirect_to(reply_assistant_index_path, alert: "這筆已處理過") unless item.status == "pending"

    if params[:decision] == "reject"
      item.update!(status: "rejected", reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      return redirect_to(reply_assistant_index_path, notice: "已標記不採用")
    end

    item.update!(question: params[:question].to_s.strip, answer: params[:answer].to_s.strip, status: "approved",
                 reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
    redirect_to reply_assistant_index_path, notice: "已核准，機器人之後可以使用這筆答案"
  rescue ActiveRecord::RecordInvalid
    redirect_to reply_assistant_index_path, alert: "問題和答案都不能空白"
  end
end
