# frozen_string_literal: true

module ReplyAssistant
  # 找跟問題最接近的知識：FAQ＋已核准問答。
  # 用中文雙字重疊做粗篩（問題比對權重較高，答案也算），問到的產品相同再加分——
  # 客人說「瘦身粉」、Chloe 答案寫「清纖粉」時，靠 Category 的產品別名對得上。
  module Knowledge
    LIMIT = 60
    PRODUCT_BONUS = 10.0
    ANSWER_SCORE_CAP = 25.0
    Entry = Struct.new(:ref, :question, :answer, keyword_init: true)

    module_function

    def all
      faqs = Faq.where.not(answer: [nil, ""]).map { |f| Entry.new(ref: "faq:#{f.id}", question: f.question, answer: f.answer) }
      items = ReplyKnowledgeItem.approved.map { |i| Entry.new(ref: "item:#{i.id}", question: i.question, answer: i.answer) }
      items + faqs
    end

    # 每個雙字用 IDF 加權：「怎麼吃」「寶貝」這種到處都有的字幾乎不算分，
    # 「空腹」「懷孕」這種少見的字才是重點。問題比對算兩倍，答案比對有上限。
    def candidates(question, entries: all, limit: LIMIT)
      target = bigrams(question)
      return [] if target.empty?

      docs = entries.map { |e| [e, bigrams(e.question), bigrams(e.answer)] }
      df = Hash.new(0)
      docs.each { |_, q, a| (q | a).each { |g| df[g] += 1 if target.include?(g) } }
      idf = target.to_h { |g| [g, Math.log((docs.size + 1.0) / (df[g] + 1))] }
      products = Category.products(question)

      docs.map { |e, q, a| [e, score(e, q, a, idf, products)] }
          .select { |_, s| s.positive? }
          .sort_by { |_, s| -s }
          .first(limit)
          .map(&:first)
    end

    def score(entry, question_grams, answer_grams, idf, products)
      by_question = (question_grams & idf.keys).sum { |g| idf[g] } * 2
      by_answer = [(answer_grams & idf.keys).sum { |g| idf[g] }, ANSWER_SCORE_CAP].min
      shared = products.any? && (Category.products(entry.question, entry.answer) & products).any?
      return 0 if by_question.zero? && !shared

      by_question + by_answer + (shared ? PRODUCT_BONUS : 0)
    end

    def find(ref)
      kind, id = ref.to_s.split(":", 2)
      case kind
      when "faq" then Faq.find_by(id: id)
      when "item" then ReplyKnowledgeItem.approved.find_by(id: id)
      end
    end

    # 產品別名先換成同一個名稱（瘦身粉、輕纖粉 → 清纖粉），雙字比對才對得上
    def bigrams(text)
      normalized = Category::PRODUCTS.reduce(text.to_s) { |t, (name, pattern)| t.gsub(pattern, name) }
      chars = normalized.downcase.gsub(/[[:space:][:punct:]]/, "").chars
      chars.each_cons(2).map(&:join).uniq
    end
  end
end
