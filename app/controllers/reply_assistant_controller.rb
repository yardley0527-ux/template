# Chloe 知識庫：回覆助手（ChloeRepliesController）找答案的來源，可篩選、移除。
class ReplyAssistantController < ApplicationController
  def index
    load_knowledge
  end

  # 知識庫問答不能修改；過期或不適用的可移除，移除後機器人不再使用。
  def remove_item
    item = ReplyKnowledgeItem.approved.find(params[:id])
    item.update!(status: "rejected", reviewed_by_user_id: current_user.id, reviewed_at: Time.current)
    redirect_to reply_assistant_index_path(q: params[:q].presence, product: params[:product].presence, topic: params[:topic].presence, anchor: "knowledge"),
                notice: "已移除，機器人不會再使用這筆答案"
  end

  private

  KNOWLEDGE_PAGE = 100

  # 關鍵字、產品和主題可以一起篩選；每排的數字是套用其他條件後的筆數。
  # 不在每次開頁都載入上萬則問答逐則分類（每次多吃 40–55MB，產生回覆時頁面每 5 秒重整，
  # 11/27 讓 web 記憶體不足 502）：分類結果存快取，只載入要顯示的那幾筆。
  def load_knowledge
    @q = params[:q].to_s.strip
    tags = knowledge_tags
    @knowledge_total = tags.size
    tags = tags.select { |id, _, _| keyword_ids.include?(id) } if @q.present?
    @product = params[:product].presence_in(ReplyAssistant::Category::PRODUCTS.keys)
    @topic = params[:topic].presence_in(ReplyAssistant::Category::TOPICS.keys)
    by_topic = @topic ? tags.select { |_, _, topics| topics.include?(@topic) } : tags
    by_product = @product ? tags.select { |_, products, _| products.include?(@product) } : tags
    @product_counts = by_topic.flat_map { |_, products, _| products }.tally.sort_by { |_, n| -n }
    @topic_counts = by_product.flat_map { |_, _, topics| topics }.tally
    matched = by_topic & by_product
    @knowledge_count = matched.size
    shown = matched.first(KNOWLEDGE_PAGE)
    items = ReplyKnowledgeItem.where(id: shown.map(&:first)).index_by(&:id)
    @knowledge_rows = shown.filter_map { |id, products, topics| items[id] && [items[id], products, topics] }
  end

  # [[id, 產品標籤, 主題標籤], ...]，知識庫有新增或移除才重算；分批讀避免一次載入全部文字
  def knowledge_tags
    scope = ReplyKnowledgeItem.approved
    key = ["reply_knowledge_tags/v1", scope.count, scope.maximum(:updated_at)&.to_f]
    Rails.cache.fetch(key, expires_in: 1.day) do
      rows = []
      scope.in_batches(of: 1000) do |batch|
        batch.order(:id).pluck(:id, :question, :answer).each do |id, question, answer|
          rows << [id, ReplyAssistant::Category.products(question, answer), ReplyAssistant::Category.topics(question, answer)]
        end
      end
      rows.sort_by(&:first)
    end
  end

  # 空白分開的關鍵字都要出現，比對時忽略空白和大小寫（答案常寫成 P D R N）。
  def keyword_ids
    @keyword_ids ||= begin
      scope = ReplyKnowledgeItem.approved
      @q.split.each do |word|
        scope = scope.where("regexp_replace(lower(question || answer), '[[:space:]]', '', 'g') LIKE ?",
                            "%#{ReplyKnowledgeItem.sanitize_sql_like(compact_text(word))}%")
      end
      scope.pluck(:id).to_set
    end
  end

  def compact_text(text)
    text.gsub(/[[:space:]]/, "").downcase
  end
end
