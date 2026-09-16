# frozen_string_literal: true

# AI數字幻覺防護的第二步（見「二、降低AI fact-check誤判」）：WeeklyMetricRegistry
# 只手動登記一小組核心指標，但實際餵給Claude的context遠不只這些——整個
# metrics JSON、風險旗標、四大燈號、週型都原封不動地被塞進prompt。商品層級
# 數字（例如全能的 lifetime_repurchase_rate_pct=56.9、trailing4_revenue_share_pct=12.0）
# 確實出現在AI輸入裡，只是沒被手動登記，過去被fact validator判定「找不到
# 相符允許值」是誤判，不是AI真的杜撰。
#
# 這裡不手動登記，而是遞迴掃描整份「實際傳給AI的context」，把每一個數字
# 葉節點都自動變成一條可比對的條目（json_path/raw_value/formatted_value/
# period/scope），跟 WeeklyMetricRegistry 手動登記的條目合併使用同一套
# 比對邏輯（見 weekly_ai_fact_validator.rb）——不是放寬驗證標準，是讓「允許
# 值清單」真正等於「AI實際看得到的所有數字」，該擋的（清單外的數字）還是擋。
class WeeklyAiContextValueIndex
  MONEY_ROUNDING   = 1
  COUNT_ROUNDING   = 0
  PERCENT_ROUNDING = 0.1

  PERIOD_PATH_HINTS = {
    "this_week" => "本週", "prev_week" => "上週", "week_before_prev" => "上上週",
    "trailing4" => "近四週平均", "trailing8" => "近八週平均", "trailing13" => "近十三週平均",
    "last_year" => "去年同週", "ytd" => "今年累計"
  }.freeze

  # 路徑最後一段的欄位名稱關鍵字，用來猜這個數字是金額/人數/百分比——只是
  # 為了決定容許誤差跟AI可能怎麼寫方向詞，猜錯也不影響「存在性」比對本身
  # （存在性用絕對值比對，money/count都用直接比對，猜錯money/count頂多
  # 誤差寬鬆度不理想，不會整條比對邏輯壞掉）。
  def self.call(context)
    new(context).call
  end

  def initialize(context)
    @context = context
  end

  def call
    entries = {}
    walk(@context, [], nil, entries)
    entries
  end

  private

  def walk(node, path, scope, entries)
    case node
    when Hash
      local_scope = node["label"] || node[:label] || scope
      node.each { |k, v| walk(v, path + [k.to_s], local_scope, entries) }
    when Array
      node.each_with_index { |v, i| walk(v, path + ["[#{i}]"], scope, entries) }
    when Numeric
      register(node, path, scope, entries)
    end
  end

  # 門檻/規則常數（warn_threshold_pct、critical_threshold_pct、
  # decline_threshold_pct 這類固定參數，跟「本週實際發生什麼」是兩回事）
  # 標成 rule_threshold，validator預設排除在存在性/方向比對候選之外
  # （見weekly_ai_fact_validator.rb）——不然像「decline_threshold_pct=5」
  # 這種設定值會跟「新客5人」這種真的觀測數字同量級撞在一起，變成方向
  # 誤判的噪音來源。
  THRESHOLD_FIELD_PATTERN = /threshold/i

  def register(value, path, scope, entries)
    json_path = path.join(".")
    field = path.last.to_s
    kind = infer_kind(field, value)
    rounding = { "money" => MONEY_ROUNDING, "count" => COUNT_ROUNDING, "percent" => PERCENT_ROUNDING }.fetch(kind)
    claim_type = field.match?(THRESHOLD_FIELD_PATTERN) ? "rule_threshold" : "observed_metric"

    entries[json_path] = {
      "metric_key" => json_path, "raw_value" => value.to_f, "formatted_value" => format_value(value, kind),
      "accepted_rounding" => rounding, "period" => infer_period(path), "scope" => scope, "kind" => kind,
      "claim_type" => claim_type
    }
  end

  def infer_kind(field, value)
    return "percent" if field.end_with?("_pct", "_percent") || field.include?("percentage")
    return "count" if field.end_with?("_count", "_customers", "_buyers", "_days", "_weeks") && value == value.to_i
    return "money" if field.include?("revenue") || field.include?("amount") || field.include?("aov")

    value.is_a?(Integer) ? "count" : "money"
  end

  def infer_period(path)
    joined = path.join(".")
    PERIOD_PATH_HINTS.each { |hint, label| return label if joined.include?(hint) }
    nil
  end

  def format_value(value, kind)
    case kind
    when "percent" then "#{value.round(1)}%"
    when "money"    then "#{delimit(value.round)}元"
    else "#{delimit(value.round)}人"
    end
  end

  def delimit(n)
    n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end
end
