# frozen_string_literal: true

# AI數字幻覺防護：拿AI寫的自由文字，逐一抓出看起來像「財務/業務數字」的
# token，比對是否能在「允許值清單」（WeeklyMetricRegistry手動登記的核心
# 指標＋WeeklyAiContextValueIndex自動掃描出的完整AI輸入context，見
# weekly_briefing_service.rb 組裝registry的地方）裡找到相符條目。
#
# 每個數字先依「claim type」分流，再用對應規則驗證——不是同一套規則套
# 全部數字（見2026-09-16收斂修正）：
#   observed_metric —— 直接引用某期的觀測值，比對允許值清單
#   derived_metric  —— 衍生計算值（差額/成長率/預測）。只有 WeeklyMetricRegistry
#                       明確用固定公式預先算好、登記了 formula/source_metric_keys
#                       的才算——validator本身不做排列組合湊數字，避免製造新誤判
#   target_metric   —— action_items[].kpi 這類AI自訂的未來KPI目標值，不拿去跟
#                       歷史事實比對（本來就不該存在於歷史資料裡），只做輕量
#                       格式檢查（非負值），結果歸在not_checked監控
#   rule_threshold  —— 黃紅燈門檻常數（warn_threshold_pct等），排除在比對
#                       候選池外，不跟本週實績數字混在一起判方向
#   date_or_identifier —— 日期／P0-2／週次，一律排除，不當財務數字處理
#
# 三態結果：
#   verified     —— 數字比對到清單裡一致的條目，且期間/方向（如果附近有
#                    對應詞、且距離夠近可以確定是修飾這個數字）也對得上
#   invalid      —— 「關鍵決策欄位」裡：(a)完全找不到相符條目，或
#                    (b)附近有期間/方向詞，距離夠近可以確定是修飾這個
#                    數字，但跟候選矛盾
#   not_checked  —— 「非關鍵欄位」的數字（不管比對結果），或關鍵欄位裡
#                    「附近有期間/方向詞但距離不夠近、無法確定修飾對象」
#                    的曖昧情況，或target_metric——都只留監控資訊，
#                    不影響quality_passed
#
# 只有 invalid 會讓 WeeklyBriefingQualityChecker 判定「需要檢查」。
class WeeklyAiFactValidator
  # 這輪修正發現的既有漏洞（2026-09-16收斂修正）：biggest_risk／
  # biggest_opportunity 過去只檢查 .description，沒檢查 .data_evidence——
  # 但支撐風險/機會判斷的實際數字通常寫在data_evidence，不是description，
  # 用人工植入錯誤驗證時才發現這個欄位形同沒被檢查，這裡補上。
  KEY_FIELD_PATHS = %w[
    executive_summary.one_liner
    executive_summary.biggest_risk.description
    executive_summary.biggest_risk.data_evidence
    executive_summary.biggest_opportunity.description
    executive_summary.biggest_opportunity.data_evidence
    business_analysis.revenue_and_forecast
    business_analysis.revenue_change_breakdown
    business_analysis.new_and_returning_customers
  ].freeze

  NOT_CHECKED_FIELD_PATHS = %w[
    executive_summary.top_findings
    business_analysis.livestream_performance
    business_analysis.membership_health
    business_analysis.product_and_repurchase
    business_analysis.next_4_week_outlook
  ].freeze

  DATE_PATTERN = %r{
    \d{4}[-/]\d{1,2}[-/]\d{1,2}
    | \d{1,2}[-/]\d{1,2}(?:\s*[~～\-]\s*\d{1,2}[-/]\d{1,2})?
  }x
  PRIORITY_PATTERN = /\bP[0-2]\b|第\d+週|Q[1-4]\b/i
  NUMBER_PATTERN = /-?\d{1,3}(?:,\d{3})+(?:\.\d+)?|-?\d+\.\d+|-?\d{3,}|-?\d+(?=\s*[%％元人])/

  DIRECTION_UP   = %w[上升 增加 成長 提升 高於 上漲].freeze
  DIRECTION_DOWN = %w[下降 減少 衰退 降低 低於 下滑 下跌].freeze
  PERIOD_KEYWORDS = { "去年同週" => "去年同週", "近四週平均" => "近四週平均", "本週" => "本週", "上週" => "上週" }.freeze

  # 期間/方向詞要離數字多近，才「有信心」認定它是在修飾這個數字，可以真的
  # 判invalid；超過這個距離但還在AMBIGUOUS範圍內，代表附近確實有這類詞，
  # 但沒把握歸屬到哪個數字，降級成not_checked，不誤判成invalid（這是這輪
  # 收斂修正的核心：同一句有兩個數字時，靠「離期間詞最近的那個數字」而不是
  # 固定字元窗口，避免像「A元反而高於上週B元」把「上週」誤配給A）。超過
  # AMBIGUOUS距離的詞視為跟這個數字無關，完全不產生claim。
  CONFIDENT_ATTACH_DISTANCE = 8
  AMBIGUOUS_ATTACH_DISTANCE = 20

  FLOAT_EPSILON = 1e-6

  def self.call(ai_report:, registry:)
    new(ai_report, registry).call
  end

  def initialize(ai_report, registry)
    @report = ai_report || {}
    @registry = (registry || {}).values
  end

  def call
    verified = 0
    invalid = []
    not_checked = []

    each_field(KEY_FIELD_PATHS) do |field_path, text|
      next if text.blank?

      if target_metric_field?(field_path)
        result = check_target_metric_text(text)
        verified += result[:verified]
        invalid.concat(result[:issues].map { |i| i.merge("field" => field_path) })
        not_checked.concat(result[:targets].map { |i| i.merge("field" => field_path) })
        next
      end

      result = check_text(text)
      verified += result[:verified]
      invalid.concat(result[:issues].map { |i| i.merge("field" => field_path) })
      not_checked.concat(result[:ambiguous].map { |i| i.merge("field" => field_path) })
    end

    each_field(NOT_CHECKED_FIELD_PATHS) do |field_path, text|
      next if text.blank?

      result = check_text(text)
      verified += result[:verified]
      not_checked.concat(result[:issues].map { |i| i.merge("field" => field_path) })
      not_checked.concat(result[:ambiguous].map { |i| i.merge("field" => field_path) })
    end

    {
      "passed"          => invalid.empty?,
      "verified_count"   => verified,
      "checked_fields"   => KEY_FIELD_PATHS,
      "monitored_fields" => NOT_CHECKED_FIELD_PATHS,
      "issues"           => invalid,
      "not_checked"      => not_checked
    }
  end

  private

  def target_metric_field?(field_path)
    field_path.end_with?(".kpi") || field_path.include?("].kpi")
  end

  def each_field(field_paths)
    es = @report["executive_summary"] || {}
    ba = @report["business_analysis"] || {}

    field_paths.each do |path|
      case path
      when "executive_summary.one_liner" then yield path, es["one_liner"]
      when "executive_summary.biggest_risk.description" then yield path, es.dig("biggest_risk", "description")
      when "executive_summary.biggest_risk.data_evidence" then yield path, es.dig("biggest_risk", "data_evidence")
      when "executive_summary.biggest_opportunity.description" then yield path, es.dig("biggest_opportunity", "description")
      when "executive_summary.biggest_opportunity.data_evidence" then yield path, es.dig("biggest_opportunity", "data_evidence")
      else
        section, key = path.split(".")
        source = section == "executive_summary" ? es : ba
        Array(source[key]).each_with_index { |t, i| yield "#{path}[#{i}]", t }
      end
    end

    if field_paths.equal?(KEY_FIELD_PATHS)
      Array(es["decisions"]).each_with_index do |d, i|
        %w[current_situation data_evidence recommendation_reason impact_if_no_decision].each do |f|
          yield "executive_summary.decisions[#{i}].#{f}", d[f]
        end
      end
      Array(@report["action_items"]).each_with_index { |a, i| yield "action_items[#{i}].kpi", a["kpi"] }
    end
  end

  # target_metric：AI自己訂的未來KPI目標，不存在於歷史資料裡是預期行為，
  # 不拿去跟allowed values比對；只做「這是不是一個合理的目標數字」的輕量
  # 檢查——負值對人數/百分比目標而言幾乎必然是錯的（拿掉日期/優先級token
  # 後仍是負值代表格式明顯有問題），其餘一律歸類target_metric、放進
  # not_checked做監控，不影響quality_passed。
  def check_target_metric_text(text)
    stripped = text.to_s.gsub(DATE_PATTERN, " ").gsub(PRIORITY_PATTERN, " ")
    verified = 0
    issues = []
    targets = []

    stripped.scan(NUMBER_PATTERN).each do |raw_token|
      value = raw_token.delete(",").to_f
      if value.negative?
        issues << { "kind" => "invalid_target_metric", "ai_value" => raw_token,
                     "message" => "「#{raw_token}」是KPI目標值卻是負數，格式明顯有問題" }
      else
        targets << { "kind" => "target_metric", "ai_value" => raw_token,
                      "message" => "「#{raw_token}」是AI自訂的未來KPI目標值，不跟歷史事實比對，僅記錄供監控" }
      end
    end

    { verified: verified, issues: issues, targets: targets }
  end

  def check_text(text)
    stripped = text.to_s.gsub(DATE_PATTERN, " ").gsub(PRIORITY_PATTERN, " ")
    verified = 0
    issues = []
    ambiguous = []

    matches = stripped.to_enum(:scan, NUMBER_PATTERN).map { Regexp.last_match }
    number_positions = matches.map { |m| [m[0], m.begin(0)] }
    period_claims = nearest_claims(stripped, number_positions, PERIOD_KEYWORDS)
    direction_claims = nearest_direction_claims(stripped, number_positions)

    matches.each do |m|
      raw_token = m[0]
      pos = m.begin(0)
      value = raw_token.delete(",").to_f
      candidates = matching_candidates(value)

      if candidates.empty?
        issues << { "kind" => "unverified_number", "ai_value" => raw_token,
                     "message" => "「#{raw_token}」在已計算的關鍵指標清單與實際AI輸入context裡都找不到相符的允許值" }
        next
      end

      period_claim = period_claims[pos]
      direction_claim = direction_claims[pos]

      period_status, period_detail = evaluate_period(candidates, period_claim)
      direction_status, direction_detail = evaluate_direction(candidates, direction_claim)

      if period_status == :invalid
        issues << { "kind" => "period_mismatch", "ai_value" => raw_token,
                     "claimed_period" => period_claim[:label], "actual_period" => period_detail["period"],
                     "message" => "「#{raw_token}」文字標成「#{period_claim[:label]}」，但這個數字實際對應的是「#{period_detail['period']}」（指標：#{period_detail['metric_key']}）" }
      elsif direction_status == :invalid
        issues << { "kind" => "direction_mismatch", "ai_value" => raw_token,
                     "expected_direction" => direction_label_for(direction_detail),
                     "message" => "「#{raw_token}」附近文字方向詞跟指標「#{direction_detail['metric_key']}」實際正負號（#{direction_detail['raw_value']}）矛盾" }
      elsif period_status == :ambiguous || direction_status == :ambiguous
        ambiguous << { "kind" => "ambiguous_reference", "ai_value" => raw_token,
                        "message" => "「#{raw_token}」附近有期間或方向詞，但距離不夠近以致無法確定是否修飾此數字，降級為監控，不判定invalid" }
      else
        verified += 1
      end
    end

    { verified: verified, issues: issues, ambiguous: ambiguous }
  end

  def direction_label_for(entry)
    entry["raw_value"].negative? ? "下降" : "上升"
  end

  # 一個數值可能同時存在多個候選條目（手動registry＋自動索引常常重疊登記
  # 同一個數字）——existence比對只要「至少一個候選」就算數字本身存在。
  # rule_threshold（黃紅燈門檻常數）排除在候選池外：那是設定值，不是本週
  # 實際發生的事，混進來會跟真的觀測數字（例如「新客5人」）同量級碰撞，
  # 變成方向判斷的噪音來源。
  def matching_candidates(value)
    @registry.select do |entry|
      next false if entry["claim_type"] == "rule_threshold"

      tolerance = entry["accepted_rounding"] + FLOAT_EPSILON
      if entry["kind"] == "percent"
        (entry["raw_value"].abs - value.abs).abs <= tolerance
      else
        (entry["raw_value"] - value).abs <= tolerance
      end
    end
  end

  # 期間狀態：:ok（沒有期間詞可比對，或比對一致）／:invalid（距離夠近、
  # 確定是修飾這個數字，但跟所有候選的period都矛盾）／:ambiguous（附近有
  # 期間詞但距離超過信心範圍，不確定歸屬）。回傳第二個值是矛盾時的
  # 「實際上是哪個候選」，供組訊息用。
  def evaluate_period(candidates, claim)
    return [:ok, nil] unless claim
    return [:ambiguous, nil] if claim[:distance] > CONFIDENT_ATTACH_DISTANCE

    single_period_candidates = candidates.reject { |c| c["kind"] == "percent" }
    return [:ok, nil] if single_period_candidates.empty?

    dated = single_period_candidates.select { |c| c["period"].present? }
    return [:ok, nil] if dated.empty?
    return [:ok, nil] if dated.any? { |c| c["period"] == claim[:label] }

    [:invalid, dated.first]
  end

  def evaluate_direction(candidates, claim)
    return [:ok, nil] unless claim
    return [:ambiguous, nil] if claim[:distance] > CONFIDENT_ATTACH_DISTANCE

    percent_candidates = candidates.select { |c| c["kind"] == "percent" }
    return [:ok, nil] if percent_candidates.empty?

    consistent = percent_candidates.any? do |c|
      down = c["raw_value"].negative?
      (claim[:direction] == :down && down) || (claim[:direction] == :up && !down)
    end
    return [:ok, nil] if consistent

    [:invalid, percent_candidates.first]
  end

  # 對每個期間關鍵字在文字裡的每一次出現，找「離它最近的數字」並把這次
  # 期間宣稱掛在那個數字的字元位置上——不是「數字前後N字內有沒有關鍵字」
  # 這種固定窗口（那樣同句兩個數字時會兩個都命中，抓錯歸屬對象）。同一個
  # 數字位置若被多個期間關鍵字出現位置候選，取距離最近的那次。
  def nearest_claims(text, number_positions, keyword_map)
    claims = {}
    keyword_map.each do |kw, label|
      scan_keyword_occurrences(text, kw) do |kw_idx|
        nearest = nearest_number(number_positions, kw_idx)
        next unless nearest

        distance = (nearest[1] - kw_idx).abs
        next if distance > AMBIGUOUS_ATTACH_DISTANCE

        existing = claims[nearest[1]]
        claims[nearest[1]] = { label: label, distance: distance } if existing.nil? || distance < existing[:distance]
      end
    end
    claims
  end

  def nearest_direction_claims(text, number_positions)
    claims = {}
    direction_map = DIRECTION_UP.map { |w| [w, :up] } + DIRECTION_DOWN.map { |w| [w, :down] }
    direction_map.each do |kw, dir|
      scan_keyword_occurrences(text, kw) do |kw_idx|
        nearest = nearest_number(number_positions, kw_idx)
        next unless nearest

        distance = (nearest[1] - kw_idx).abs
        next if distance > AMBIGUOUS_ATTACH_DISTANCE

        existing = claims[nearest[1]]
        claims[nearest[1]] = { direction: dir, distance: distance } if existing.nil? || distance < existing[:distance]
      end
    end
    claims
  end

  def nearest_number(number_positions, idx)
    return nil if number_positions.empty?

    number_positions.min_by { |_, pos| (pos - idx).abs }
  end

  def scan_keyword_occurrences(text, kw)
    start = 0
    while (idx = text.index(kw, start))
      yield idx
      start = idx + kw.length
    end
  end
end
