# Chloe 回覆助手（測試）：貼上客人問題，看已核准答案或 AI 草稿，核准後存進知識庫。不會發訊息給客人。
class ReplyAssistantController < ApplicationController
  def index
    @drafts = ReplyDraft.recent.limit(30)
    @refreshing = @drafts.any? { |d| d.status == "generating" }
    @approved_count = ReplyKnowledgeItem.approved.count
    @faq_count = Faq.where.not(answer: [nil, ""]).count
    load_knowledge
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

  # 知識庫問答：可修改，過期或不適用的可移除，移除後機器人不再使用。
  def update_item
    item = ReplyKnowledgeItem.approved.find(params[:id])
    back = reply_assistant_index_path(product: params[:product].presence, topic: params[:topic].presence, anchor: "knowledge")

    if params[:decision] == "reject"
      item.update!(status: "rejected", reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
      return redirect_to(back, notice: "已移除，機器人不會再使用這筆答案")
    end

    item.update!(question: params[:question].to_s.strip, answer: params[:answer].to_s.strip,
                 reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
    redirect_to back, notice: "已儲存"
  rescue ActiveRecord::RecordInvalid
    redirect_to back, alert: "問題和答案都不能空白"
  end

  private

  # 產品和主題可以交叉篩選；每排的數字是套用另一排條件後的筆數。
  def load_knowledge
    items = ReplyKnowledgeItem.approved.order(:id).map { |i| [i, i.products, i.topics] }
    @product = params[:product].presence_in(ReplyAssistant::Category::PRODUCTS.keys)
    @topic = params[:topic].presence_in(ReplyAssistant::Category::TOPICS.keys)
    by_topic = @topic ? items.select { |_, _, topics| topics.include?(@topic) } : items
    by_product = @product ? items.select { |_, products, _| products.include?(@product) } : items
    @knowledge_total = items.size
    @product_counts = by_topic.flat_map { |_, products, _| products }.tally.sort_by { |_, n| -n }
    @topic_counts = by_product.flat_map { |_, _, topics| topics }.tally
    @knowledge_rows = by_topic & by_product
  end
end
