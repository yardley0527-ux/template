# frozen_string_literal: true

# 老闆30秒摘要的「四大經營燈號」——營收／新客／舊客與回購／商品與庫存。
#
# 規格明確要求「燈號必須由程式先計算，不要完全交給LLM自由判斷」，所以這裡
# 直接重用 WeeklyRiskFlagDetector 已經算好的旗標（同一套門檻常數，不重新
# 發明一套新規則）：該領域有 high 旗標＝紅燈，只有 medium 旗標＝黃燈，都
# 沒有＝綠燈；領域本身缺乏可比較基準時＝灰燈（資料不足，不能判斷），灰燈
# 判斷優先於旗標判斷（沒有基準時旗標本身也不可信）。AI 不參與燈號本身的
# 顏色判定，只能在後續敘述文字裡引用這裡算好的結果。
class WeeklyBusinessSignalClassifier
  AREA_DEFS = [
    { area: "revenue",           label: "營收",      categories: %w[revenue] },
    { area: "new_customer",      label: "新客",      categories: %w[new_customer] },
    { area: "old_customer",      label: "舊客與回購", categories: %w[old_customer] },
    { area: "product_inventory", label: "商品與庫存", categories: %w[product_inventory] }
  ].freeze

  STATUS_LABELS = { "green" => "綠燈", "yellow" => "黃燈", "red" => "紅燈", "gray" => "灰燈" }.freeze

  def self.call(metrics, risk_flags)
    new(metrics, risk_flags).call
  end

  def initialize(metrics, risk_flags)
    @m = metrics
    @flags = Array(risk_flags)
  end

  def call
    signals = AREA_DEFS.map { |d| build_signal(d) }
    {
      "signals"            => signals,
      "can_be_used_for"     => signals.reject { |s| s["status"] == "gray" }.map { |s| "#{s['area_label']}方向的經營判斷" },
      "cannot_be_used_for"  => signals.select { |s| s["status"] == "gray" }.map { |s| "#{s['area_label']}方向的經營判斷（#{s['reason']}）" }
    }
  end

  private

  def build_signal(def_)
    area_flags = @flags.select { |f| def_[:categories].include?((f[:category] || f["category"]).to_s) }
    high_flags   = area_flags.select { |f| (f[:severity] || f["severity"]) == "high" }
    medium_flags = area_flags.select { |f| (f[:severity] || f["severity"]) == "medium" }

    gray_reason = gray_reason_for(def_[:area])

    status, reason =
      if gray_reason
        ["gray", gray_reason]
      elsif high_flags.any?
        ["red", flag_labels(high_flags)]
      elsif medium_flags.any?
        ["yellow", flag_labels(medium_flags)]
      else
        ["green", "本週無已觸發的#{def_[:label]}風險旗標"]
      end

    {
      "area" => def_[:area], "area_label" => def_[:label], "status" => status, "status_label" => STATUS_LABELS.fetch(status),
      "result" => result_summary(def_[:area]),
      "reason" => reason,
      "recommended_direction" => recommended_direction(def_[:area], status)
    }
  end

  def flag_labels(flags)
    flags.map { |f| WeeklyRiskFlagDetector::KEY_LABELS[(f[:key] || f["key"]).to_s] }.compact.join("；")
  end

  # ── 各領域「灰燈」條件：缺乏可比較基準時，旗標本身也不可信，優先判灰燈 ──
  def gray_reason_for(area)
    case area
    when "revenue"
      basis = @m.dig("revenue_progress", "comparable_basis")
      "找不到可比較的歷史同類型週基準" if basis.nil? || basis["growth_pct"].nil?
    when "new_customer"
      avg = @m.dig("new_vs_returning", "trailing4_weekly_avg", "new_customers").to_f
      "近4週新客平均為0，沒有基準可比較" if avg.zero?
    when "old_customer"
      avg = @m.dig("new_vs_returning", "trailing4_weekly_avg", "returning_customers").to_f
      "近4週舊客回購平均為0，沒有基準可比較" if avg.zero?
    when "product_inventory"
      products = Array(@m.dig("product_repurchase", "products"))
      "目前沒有追蹤中的商品" if products.empty?
    end
  end

  def result_summary(area)
    case area
    when "revenue"
      rp = @m["revenue_progress"] || {}
      basis = rp["comparable_basis"] || {}
      "本週營收 NT$#{format_num(rp['this_week_revenue'])}，較#{basis['basis_label']} #{format_pct(basis['growth_pct'])}"
    when "new_customer"
      nvr = @m.dig("new_vs_returning", "this_week") || {}
      avg = @m.dig("new_vs_returning", "trailing4_weekly_avg", "new_customers")
      "本週新客 #{nvr['new_customers']} 人，近4週平均 #{avg} 人"
    when "old_customer"
      nvr = @m.dig("new_vs_returning", "this_week") || {}
      avg = @m.dig("new_vs_returning", "trailing4_weekly_avg", "returning_customers")
      "本週舊客回購 #{nvr['returning_customers']} 人，近4週平均 #{avg} 人"
    when "product_inventory"
      products = Array(@m.dig("product_repurchase", "products"))
      out_of_stock = products.select { |p| p["availability_status"] == "out_of_stock" }
      "追蹤中商品 #{products.size} 項，缺貨中 #{out_of_stock.size} 項#{out_of_stock.any? ? "（#{out_of_stock.map { |p| p['label'] }.join('、')}）" : ''}"
    end
  end

  def recommended_direction(area, status)
    return "維持現有做法，持續依既定節奏監控" if status == "green"
    return "先補齊上面標示缺少的資料，才能可靠判斷這個面向" if status == "gray"

    topic = { "revenue" => "revenue", "new_customer" => "new_customer", "old_customer" => "old_customer", "product_inventory" => "product_inventory" }.fetch(area)
    directions = WeeklyInvestigationDirections.for(topic)
    directions.any? ? "建議檢查：#{directions.join('、')}" : "建議依風險旗標明細逐一排查"
  end

  def format_num(v)
    v.nil? ? "—" : v.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end

  def format_pct(v)
    v.nil? ? "無可比較基準" : "#{v.positive? ? '+' : ''}#{v.round(1)}%"
  end
end
