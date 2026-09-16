# frozen_string_literal: true

# 檢查 WeeklyMandatoryRiskTopics 算出的「強制風險主題」，有沒有在AI自己寫的
# 「本週最大風險」「老闆決策事項」「行動清單」任一處被點名——只看AI自由
# 文字欄位，不看程式保證涵蓋每個紅燈的 program_action_items（那是另一個
# 獨立保底管道，見 WeeklyActionItemBuilder；這裡要驗證的是AI敘述本身有沒有
# 抓對重點，不能拿「反正程式那邊一定有」當作AI可以不提的理由）。
class WeeklyMandatoryRiskCoverageChecker
  def self.call(ai_report:, mandatory_topics:)
    new(ai_report, mandatory_topics).call
  end

  def initialize(ai_report, mandatory_topics)
    @report = ai_report || {}
    @topics = Array(mandatory_topics)
  end

  def call
    text = combined_text
    uncovered = @topics.reject { |t| topic_covered?(t, text) }

    { "covered" => uncovered.empty?, "mandatory_topics" => @topics, "uncovered_topics" => uncovered }
  end

  private

  def topic_covered?(topic, text)
    anchors  = Array(topic["anchor_words"])
    problems = Array(topic["problem_words"])
    return false if anchors.empty?

    anchors.any? { |a| a.present? && text.include?(a) } && problems.any? { |p| text.include?(p) }
  end

  def combined_text
    es = @report["executive_summary"] || {}
    parts = [es.dig("biggest_risk", "description"), es.dig("biggest_risk", "data_evidence")]

    Array(es["decisions"]).each do |d|
      parts.concat(d.values_at("question", "current_situation", "data_evidence", "recommendation_reason", "impact_if_no_decision"))
    end
    Array(@report["action_items"]).each { |a| parts.concat(a.values_at("action", "linked_decision", "kpi")) }

    parts.compact.join(" ")
  end
end
