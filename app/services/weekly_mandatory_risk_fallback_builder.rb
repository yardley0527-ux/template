# frozen_string_literal: true

# AI重試一次後仍然沒有點名強制風險主題時的最後手段：不顯示AI原本寫的、
# 漏掉重點的 biggest_risk，改用程式從旗標證據直接組出來的版本頂替——寧可
# 文筆生硬，也不能讓老闆讀到一份沒提到「新客不足」或「全能缺貨」的最大風險。
# 每一句都可以回溯到 topic["evidence"]（風險旗標本身的證據），不新增任何
# metrics以外的數字。
class WeeklyMandatoryRiskFallbackBuilder
  def self.call(uncovered_topics:)
    new(uncovered_topics).call
  end

  def initialize(uncovered_topics)
    @topics = Array(uncovered_topics)
  end

  def call
    return nil if @topics.empty?

    {
      "description"      => description,
      "data_evidence"    => @topics.map { |t| evidence_sentence(t) }.join("；"),
      "program_generated" => true,
      "program_generated_reason" => "AI兩次回應皆未在最大風險／老闆決策／行動清單提及以下已知最高優先級紅燈：#{@topics.map { |t| t['label'] }.join('、')}，已改用程式生成版本"
    }
  end

  private

  def description
    return @topics.first["label"] if @topics.size == 1

    "#{@topics.map { |t| t['label'] }.join('與')}同時發生"
  end

  def evidence_sentence(topic)
    ev = topic["evidence"] || {}
    reasons = Array(ev["reasons"]).join("；")
    numeric = ev.except("reasons", "label", "product_key").filter_map { |k, v| "#{k}=#{v}" unless v.nil? }.join("、")
    [topic["label"], reasons.presence, numeric.presence].compact.join("；")
  end
end
