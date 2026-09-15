# frozen_string_literal: true

# 驗證 Claude 回傳並解析後的 JSON 是否真的「有內容」，不是只有語法合法。
#
# 2026-09-15 第四輪修正的根因：WeeklyBriefingService 舊版邏輯是「JSON.parse
# 沒有丟例外＝成功」，但 executive_summary 語法上合法卻可以是 {}（AI 沒填
# 任何欄位、或欄位名稱對不上），這時舊版仍然存成 status: "success"，導致
# 正式站出現「AI API 成功」但判斷依據/信心/風險/機會/決策全部空白的報告。
#
# 這支 service 只做「必要欄位是否存在且不是空殼」的判斷,不做語意品質評分
# （語意品質是 WeeklyBriefingQualityChecker 的事，那是產生成功之後的第二層
# 檢查；這裡是產生「算不算成功」的第一層關卡）。
class WeeklyBriefingResponseValidator
  REQUIRED_DECISION_FIELDS = %w[
    question current_situation data_evidence option_a option_b
    recommended_option recommendation_reason impact_if_no_decision next_week_kpi confidence
  ].freeze

  def self.call(parsed)
    new(parsed).call
  end

  def initialize(parsed)
    @p = parsed || {}
  end

  def call
    missing = []
    exec_summary = @p["executive_summary"]

    if blank?(exec_summary)
      missing << "executive_summary"
      return result(missing)
    end

    missing << "executive_summary.one_liner"      if blank?(exec_summary["one_liner"])
    missing << "executive_summary.status_basis"    if blank?(exec_summary["status_basis"])
    missing << "executive_summary.top_findings"    if blank?(exec_summary["top_findings"])
    missing << "executive_summary.biggest_risk"        if blank?(exec_summary.dig("biggest_risk", "description"))
    missing << "executive_summary.biggest_opportunity"  if blank?(exec_summary.dig("biggest_opportunity", "description"))

    decisions = Array(exec_summary["decisions"])
    if decisions.empty?
      missing << "executive_summary.decisions"
    else
      decisions.each_with_index do |d, i|
        REQUIRED_DECISION_FIELDS.each do |field|
          missing << "decisions[#{i}].#{field}" if blank?(d[field])
        end
      end
    end

    result(missing)
  end

  private

  def result(missing)
    { valid: missing.empty?, missing_fields: missing }
  end

  # nil、空字串（含純空白）、空陣列、空Hash 都算「空殼」；純數字0跟false不算
  # （避免以後有欄位合法值是0時被誤判）。
  def blank?(value)
    case value
    when nil then true
    when String then value.strip.empty?
    when Array, Hash then value.empty?
    else false
    end
  end
end
