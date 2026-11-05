# frozen_string_literal: true

module ReplyAssistant
  # 找跟問題最接近的知識：FAQ＋已核准問答。用中文雙字重疊做粗篩，再交給 Claude 判斷。
  module Knowledge
    LIMIT = 30
    Entry = Struct.new(:ref, :question, :answer, keyword_init: true)

    module_function

    def all
      faqs = Faq.where.not(answer: [nil, ""]).map { |f| Entry.new(ref: "faq:#{f.id}", question: f.question, answer: f.answer) }
      items = ReplyKnowledgeItem.approved.map { |i| Entry.new(ref: "item:#{i.id}", question: i.question, answer: i.answer) }
      items + faqs
    end

    def candidates(question, entries: all, limit: LIMIT)
      target = bigrams(question)
      entries.map { |e| [e, (bigrams(e.question) & target).size] }
             .select { |_, score| score.positive? }
             .sort_by { |_, score| -score }
             .first(limit)
             .map(&:first)
    end

    def find(ref)
      kind, id = ref.to_s.split(":", 2)
      case kind
      when "faq" then Faq.find_by(id: id)
      when "item" then ReplyKnowledgeItem.approved.find_by(id: id)
      end
    end

    def bigrams(text)
      chars = text.to_s.downcase.gsub(/[[:space:][:punct:]]/, "").chars
      chars.each_cons(2).map(&:join).uniq
    end
  end
end
