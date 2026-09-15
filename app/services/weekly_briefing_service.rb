# frozen_string_literal: true

require "net/http"

# 每週營運檢討報告：WeeklyMetricsService 算出所有確定的數字（人數/營收/比例/
# 成長率/客單價/回購率/升降級數量/年度營收缺口/年底營收預測），連同
# WeeklyRiskFlagDetector 已觸發的風險旗標一起交給 Claude API，只請 AI 做
# 解讀／歸因假設／風險說明／優先排序／改善建議／待辦文字化——所有數字都由
# 程式先算好，AI 不重新計算任何數字，也不能生成客戶名單（見
# WeeklyBriefingTodoTargetResolver）。
#
# 跟 DailyBriefingService 是同一種落地模式：生成後存進 weekly_briefings，
# 頁面只讀已落地資料，不即時呼叫 API。同一週重新產生（regenerate）會更新
# 同一筆 weekly_briefings row（week_start 唯一索引)，不會新增重複資料。
class WeeklyBriefingService
  CLAUDE_API_URL  = "https://api.anthropic.com/v1/messages"
  MODEL           = "claude-opus-4-8"
  PROMPT_VERSION  = "v1"

  def self.call(week_start: Date.current)
    new(week_start).call
  end

  def initialize(week_start)
    @period = WeeklyPeriod.new(week_start)
  end

  def call
    briefing = WeeklyBriefing.for_week(@period.week_start)
    briefing.week_end = @period.week_end

    metrics = WeeklyMetricsService.call(week_start: @period.week_start)
    risk_flags = WeeklyRiskFlagDetector.call(metrics)

    api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
    if api_key.blank?
      briefing.update!(status: "failed", metrics: metrics, meta: { "risk_flags" => risk_flags },
                        error_message: "ANTHROPIC_API_KEY 未設定")
      return briefing
    end

    raw = call_claude(build_prompt(metrics, risk_flags), api_key)
    parsed = parse_response(raw)

    ActiveRecord::Base.transaction do
      briefing.update!(
        status:         "success",
        metrics:        metrics,
        ai_report:      parsed.except("todos"),
        error_message:  nil,
        model:          MODEL,
        prompt_version: PROMPT_VERSION,
        generated_at:   Time.current,
        meta:           { "risk_flags" => risk_flags }
      )
      upsert_todos!(briefing, parsed["todos"])
    end

    briefing
  rescue StandardError => e
    Rails.logger.error("[WeeklyBriefingService] #{e.class}: #{e.message}")
    briefing ||= WeeklyBriefing.for_week(@period.week_start)
    briefing.update!(status: "failed", metrics: metrics || briefing.metrics.presence || {},
                      error_message: "#{e.class}: #{e.message}")
    briefing
  end

  private

  def upsert_todos!(briefing, raw_todos)
    seen_keys = []

    Array(raw_todos).each do |t|
      next unless t.is_a?(Hash) && t["title"].present?

      target_query = t["target_query"].is_a?(Hash) ? t["target_query"] : {}
      dedupe_key = build_dedupe_key(t, target_query)
      seen_keys << dedupe_key

      resolution = WeeklyBriefingTodoTargetResolver.call(target_query)

      todo = briefing.todos.find_or_initialize_by(dedupe_key: dedupe_key)
      todo.title          = t["title"].to_s.truncate(255)
      todo.description    = t["description"]
      todo.priority        = WeeklyBriefingTodo::PRIORITIES.include?(t["priority"]) ? t["priority"] : "medium"
      todo.suggested_role  = t["suggested_role"]
      todo.due_date        = parse_date(t["due_date"])
      todo.data_issue      = t["data_issue"]
      todo.target_segment  = t["target_segment"]
      todo.target_query    = target_query
      todo.target_count    = resolution[:resolved] ? resolution[:count] : nil
      todo.expected_kpi    = t["expected_kpi"]
      todo.status        ||= "pending"
      todo.save!
    end

    # 只清掉「還沒被處理」且這次沒有再被 AI 提到的舊建議；已經打勾完成的
    # 保留下來當作歷史紀錄，不因為這次措辭不同就被誤刪。
    briefing.todos.pending.where.not(dedupe_key: seen_keys).destroy_all if seen_keys.any?
  end

  # 優先用結構化的 target_query 當指紋（type+條件），重新產生時只要目標客群
  # 條件沒變就會比對到同一列，不受 AI 措辭微調影響；沒有 target_query 的
  # 純文字待辦才退回用標題當指紋。
  def build_dedupe_key(todo_hash, target_query)
    basis = target_query["type"].present? ? target_query.sort.to_h.to_json : todo_hash["title"].to_s
    Digest::SHA256.hexdigest(basis)[0, 40]
  end

  def parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def build_prompt(metrics, risk_flags)
    <<~PROMPT
      你是一家保健食品電商公司的營運分析幕僚。以下是本週（#{metrics["period"]["week_start"]} ~ #{metrics["period"]["week_end"]}）
      的完整結構化營運數據（JSON，程式已經算好所有數字，你不需要、也不可以自己重新計算或推翻裡面任何一個數字）：

      ＝＝ 結構化數據 ＝＝
      #{metrics.to_json}

      ＝＝ 已觸發的風險旗標（明確條件式偵測，不是 AI 判斷）＝＝
      #{risk_flags.to_json}

      請針對以上資料，產出給老闆與營運主管看的繁體中文週報，只輸出 JSON（不要 markdown code fence、不要任何其他文字），格式：
      {
        "one_liner": "一句話結論",
        "key_numbers": [{"label": "指標名稱", "value": "本期數字", "compare_label": "比較基準", "compare_value": "比較數字", "delta_pct": 數字或null}],
        "wins": [{"point": "做得好的地方", "data": "實際數據", "compare": "比較對象", "why": "為什麼判斷做得好", "recommendation": "延續或放大的建議"}],
        "issues": [{"point": "做得不好的地方", "data": "實際數據", "gap": "跟上週/近4週/去年同期的差距", "possible_cause": "可能原因", "impact": "影響程度", "consequence": "若不處理的後果"}],
        "risks": [{"risk": "風險說明", "trigger_condition": "對應到上面哪個風險旗標＋觸發門檻", "evidence": "對應的數據"}],
        "priorities": [{"problem": "問題", "evidence": "數據證據", "action": "建議行動", "target_segment": "建議鎖定客群（文字描述）", "expected_kpi": "預期改善指標", "review_method": "下週驗收方式"}],
        "todos": [{"title": "任務名稱", "description": "任務說明", "priority": "high|medium|low", "suggested_role": "建議負責角色", "due_date": "YYYY-MM-DD", "data_issue": "對應的數據問題", "target_segment": "目標客群文字描述", "target_query": {"type": "...", "...": "..."}, "expected_kpi": "預期KPI"}]
      }

      規則：
      - 每一條 wins/issues 都必須引用結構化數據裡的真實數字，不能只寫「營收上升/下降」這種空話——要拆解是購買人數、客單價、新客、舊客、卡別結構還是商品組合造成的。
      - risks 陣列只能對應上面「已觸發的風險旗標」清單逐一寫成說明，不要自己發明清單以外的風險；旗標清單是空陣列時，risks 也要是空陣列。
      - priorities 依「營收影響 × 緊急程度 × 可執行性」排序，只保留最值得處理的 3~5 項。
      - todos 是把 priorities 轉成可直接執行的任務，不要只給建議；每項盡量帶上 target_query（可用類型：product_overdue{product_key,min_days,max_days}、product_due_soon{product_key,within_days}、dormant_member{level,min_silent_days}）方便系統自動抓名單人數；抓不到對應類型就把 target_query 留空物件 {}，並在 target_segment 用文字說清楚條件，不要虛構人數或 email。
      - 直播區塊（livestreams.events）如果是空陣列，代表本期間沒有直播，wins/issues 不要虛構直播相關內容。
      - membership.near_threshold_note 說明「即將降級/接近升級門檻」這項資料不足，issues/priorities 若想提到這件事，只能引用這個說明，不要自己編門檻數字。
      - 任何資料不足、无法從上面 JSON 推得的結論，一律寫「資料不足，需人工確認」，不要虛構活動、折扣或成本。
      - 只根據給定的 JSON 數據，不要推測數據沒有涵蓋的事。
    PROMPT
  end

  def call_claude(prompt, api_key)
    uri  = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 180

    req = Net::HTTP::Post.new(uri)
    req["x-api-key"]         = api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = {
      model:      MODEL,
      max_tokens: 8000,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(req)
    body     = JSON.parse(response.body)
    raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"

    body.dig("content", 0, "text").to_s
  end

  def parse_response(text)
    json = text[/\{.*\}/m]
    raise "AI 回應不含 JSON：#{text.truncate(200)}" if json.nil?

    parsed = JSON.parse(json)
    %w[one_liner key_numbers wins issues risks priorities todos].each_with_object({}) do |key, out|
      out[key] = key == "one_liner" ? parsed[key].to_s : Array(parsed[key])
    end
  end
end
