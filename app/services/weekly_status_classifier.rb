# frozen_string_literal: true

# 「本週整體狀態」是老闆決策摘要的第一件事，用固定規則算，不交給 AI 自由
# 判斷——同一組數字重跑一定要得到同一個狀態，AI 只負責把這個狀態寫成一句話
# 結論跟判斷依據的文字，不能自己選別的狀態。
class WeeklyStatusClassifier
  STATUSES = %w[
    healthy_growth growth_with_concerns flat short_term_pullback
    structural_decline high_risk insufficient_data
  ].freeze

  LABELS = {
    "healthy_growth"      => "健康成長",
    "growth_with_concerns" => "成長但有隱憂",
    "flat"                 => "大致持平",
    "short_term_pullback"  => "短期回落",
    "structural_decline"   => "結構性衰退",
    "high_risk"            => "高風險",
    "insufficient_data"    => "資料不足無法判斷"
  }.freeze

  def self.call(metrics, risk_flags)
    new(metrics, risk_flags).call
  end

  def initialize(metrics, risk_flags)
    @m = metrics
    @flags = risk_flags
  end

  def call
    comparable = @m.dig("revenue_progress", "comparable_basis")
    return build("insufficient_data", "low", ["找不到可比較基準的歷史同類型週（#{comparable&.dig('basis_note')}）"]) if comparable.nil? || comparable["growth_pct"].nil?

    growth = comparable["growth_pct"].to_f
    consecutive_decline = @flags.any? { |f| f[:key] == "consecutive_revenue_decline" }
    # consecutive_revenue_decline 這個旗標本身severity是high——如果直接把它
    # 算進high_count，「單純連續兩週下降、沒有其他高風險旗標」這個情境會被
    # high_count>=1 && consecutive_decline 誤判成high_risk，永遠到不了
    # structural_decline分支。這裡把它排除在外，只用「其他」高風險旗標數量
    # 判斷是否要再往上升級成high_risk。
    other_high_count = @flags.count { |f| f[:severity] == "high" && f[:key] != "consecutive_revenue_decline" }
    high_count = @flags.count { |f| f[:severity] == "high" }
    medium_count = @flags.count { |f| f[:severity] == "medium" }
    sample_size = comparable["sample_size"].to_i

    reasons = [
      "可比較基準（#{comparable['basis_label']}，樣本#{sample_size}週）營收成長率 #{growth.round(1)}%",
      "高風險旗標 #{high_count} 項、中風險旗標 #{medium_count} 項"
    ]
    reasons << "已連續2週營收下降" if consecutive_decline

    status =
      if other_high_count >= 2 || (other_high_count >= 1 && consecutive_decline)
        "high_risk"
      elsif consecutive_decline
        "structural_decline"
      elsif growth <= -15
        "short_term_pullback"
      elsif growth <= -5
        medium_count.positive? ? "short_term_pullback" : "flat"
      elsif growth < 3
        medium_count.positive? ? "growth_with_concerns" : "flat"
      elsif medium_count.positive? || high_count.positive?
        "growth_with_concerns"
      else
        "healthy_growth"
      end

    confidence =
      if sample_size >= 4 && high_count.zero?
        "high"
      elsif sample_size >= 2
        "medium"
      else
        "low"
      end
    reasons << "可比較基準樣本數偏少（#{sample_size}週），信心水準降級" if sample_size < 2

    build(status, confidence, reasons)
  end

  private

  def build(status, confidence, reasons)
    { "status" => status, "status_label" => LABELS.fetch(status), "confidence" => confidence, "reasons" => reasons }
  end
end
