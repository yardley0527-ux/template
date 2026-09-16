# frozen_string_literal: true

# 「最大風險不能只依賴Prompt」的程式保底第一步：從已觸發的紅燈裡，用固定
# 業務優先序（不是資料順序）算出「這份報告無論如何都要點名的風險主題」。
#
# 分層邏輯（TIER_GROUPS，由上到下）：
#   1) new_customer／product_inventory：「今天沒介入，這筆機會就永久消失」
#      的急迫風險——流失的潛在新客不會自動回來，缺貨商品今天賣不出去的
#      單也不會自動補上，兩者性質相近（都是「機會流失」而非「已發生虧損」），
#      放同一層，可能同時中選、組成複合描述。
#   2) revenue：營收本身通常是新客/舊客/客單價變動後的「聚合結果」，已經
#      被 revenue_and_forecast／revenue_change_breakdown 拆解說明過，重複
#      當成一個獨立最大風險主題會顯得空泛（「營收下降」沒有告訴老闆該做
#      什麼），所以只有在第1層完全沒有高風險旗標時才輪到它。
#   3) old_customer：這期資料常伴隨YoY仍成長的正面訊號（回購客單價/營收
#      年增），容易同時是biggest_opportunity的素材，不搶第一層的強制順位，
#      但沒有更高層旗標時仍要被涵蓋，不能完全不提。
#   4) membership：影響面最小、變動最慢，殿後。
#
# 只挑第一個「有high旗標」的層，同層所有high旗標一起變成 mandatory topics
# （可能是1個，也可能像「新客不足＋全能缺貨」這樣2個同時中選）。沒有任何
# high旗標時回傳空陣列，不強制。
class WeeklyMandatoryRiskTopics
  TIER_GROUPS = [
    %w[new_customer product_inventory],
    %w[revenue],
    %w[old_customer],
    %w[membership]
  ].freeze

  def self.call(risk_flags)
    new(risk_flags).call
  end

  def initialize(risk_flags)
    @flags = Array(risk_flags).map { |f| f.is_a?(Hash) ? f.with_indifferent_access : f }
  end

  def call
    high = @flags.select { |f| f["severity"] == "high" }
    return [] if high.empty?

    tier = TIER_GROUPS.find { |cats| high.any? { |f| cats.include?(f["category"]) } }
    return [] unless tier

    high.select { |f| tier.include?(f["category"]) }.map { |f| build_topic(f) }
  end

  private

  # AI措辭無法預先窮舉（例如「新客人數較近4週平均下降70.6%」不會出現「新客
  # 不足」這種固定短語），所以涵蓋判定改成「錨點詞（識別主題本身）」+「問題
  # 詞（表達方向是負面的）」兩組都要出現在AI文字裡（不要求相鄰），比對死板
  # 完整短語更貼近真實文字，同時還是比「隨便出現『新客』兩個字就算涵蓋」
  # 嚴謹——纯錨點詞會把「新客營收較去年同週成長」這種正面敘述也誤判成涵蓋。
  PROBLEM_WORDS = %w[不足 下降 轉弱 流失 偏低 過低 減少 下滑 警戒 明顯低於 明顯下降].freeze

  def build_topic(flag)
    key = flag["key"]
    evidence = (flag["evidence"] || {}).with_indifferent_access
    label = key == "product_stockout_risk" ? "#{evidence['label']}缺貨" : WeeklyRiskFlagDetector::KEY_LABELS.fetch(key, key)
    anchors, problems = topic_words(flag["category"], evidence)

    {
      "topic_key" => key, "label" => label, "category" => flag["category"], "severity" => flag["severity"],
      "anchor_words" => anchors, "problem_words" => problems, "evidence" => evidence
    }
  end

  def topic_words(category, evidence)
    case category
    when "new_customer"      then [["新客"], PROBLEM_WORDS]
    when "product_inventory" then [[evidence["label"]].compact, ["缺貨"]]
    when "revenue"            then [["營收"], PROBLEM_WORDS]
    when "old_customer"      then [["舊客"], PROBLEM_WORDS]
    when "membership"        then [["降級", "淨降級"], [""]] # 「降級」本身已是負面詞，problem_words給空字串等同不額外要求
    else [[], []]
    end
  end
end
