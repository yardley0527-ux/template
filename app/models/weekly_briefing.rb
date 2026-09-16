# frozen_string_literal: true

# 每週營運檢討報告：WeeklyBriefingService 生成後落地一份（週一為 week_start），
# 首頁與 /weekly_briefings 只讀已落地的資料——不即時呼叫 API，可回溯、成本可控。
# 跟 DailyBriefing 是同一種設計（見 app/services/daily_briefing_service.rb）。
class WeeklyBriefing < ApplicationRecord
  # invalid_response：Claude API 呼叫本身成功（HTTP 200、JSON 語法合法），
  # 但驗證後發現必要欄位缺失或空殼（重試一次仍然缺）——跟 failed（API呼叫
  # 失敗/JSON語法錯誤/沒有金鑰）是不同的失敗模式，故意分開，畫面文案也不同。
  STATUSES = %w[pending success failed invalid_response].freeze

  # 背景重新產生逾期還沒清掉 regeneration_started_at（job 卡死/process 被
  # 重啟）視為過期，不再顯示「產生中」卡住畫面——上游快取刷新＋最多3次
  # Opus API往返，正常情況下不會超過這個時間。
  REGENERATION_TIMEOUT = 15.minutes

  has_many :todos, class_name: "WeeklyBriefingTodo", dependent: :destroy, inverse_of: :weekly_briefing

  validates :week_start, presence: true, uniqueness: true
  validates :week_end, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :history, -> { order(week_start: :desc) }

  def self.latest
    order(week_start: :desc).first
  end

  def self.for_week(week_start)
    find_or_initialize_by(week_start: week_start)
  end

  # ── 第一部分：老闆決策摘要 ─────────────────────────────────────
  def executive_summary
    ai_report["executive_summary"] || {}
  end

  # 注意：不能叫 `status`——那是本筆 AR row 自己的產生狀態欄位
  # （pending/success/failed，見上面 validates :status），跟這裡「本週整體
  # 經營狀態」（healthy_growth/high_risk/...）是完全不同的兩件事，撞名會
  # 直接蓋掉 AttributeMethods 產生的欄位讀取方法（曾經真的因為這樣讓
  # status= 寫得進去、status 卻永遠讀回 nil，導致 status inclusion 驗證
  # 失敗）。
  def business_status
    executive_summary["status"]
  end

  def business_status_label
    executive_summary["status_label"]
  end

  def one_liner
    executive_summary["one_liner"]
  end

  def top_findings
    Array(executive_summary["top_findings"])
  end

  def decisions
    Array(executive_summary["decisions"])
  end

  def biggest_risk
    executive_summary["biggest_risk"]
  end

  def biggest_opportunity
    executive_summary["biggest_opportunity"]
  end

  # ── 第二部分：經營分析（各段落是條列式重點，不是單一大段落）───────
  def business_analysis
    ai_report["business_analysis"] || {}
  end

  # ── 第三部分：決策後的執行方向 ───────────────────────────────────
  def action_items
    Array(ai_report["action_items"])
  end

  # ── 風險（含 severity，來自 WeeklyRiskFlagDetector，AI 只負責文字化）──
  def risk_flags
    Array(meta["risk_flags"]).map(&:with_indifferent_access)
  end

  # ── 四大經營燈號／週型標題／下週行動清單：全部由程式規則算出（見
  # WeeklyBusinessSignalClassifier／WeeklyHeadlineClassifier／
  # WeeklyActionItemBuilder），跟 AI 是否成功產生報告無關——failed／
  # invalid_response 狀態下這幾個欄位一樣有值，畫面可以照常顯示。──
  def business_signals
    Array(meta.dig("business_signals", "signals")).map { |s| s.with_indifferent_access }
  end

  def signals_can_be_used_for
    Array(meta.dig("business_signals", "can_be_used_for"))
  end

  def signals_cannot_be_used_for
    Array(meta.dig("business_signals", "cannot_be_used_for"))
  end

  def headline
    (meta["headline"] || {}).with_indifferent_access
  end

  def headline_display
    headline["display"]
  end

  def program_action_items
    Array(meta["program_action_items"]).map { |i| i.with_indifferent_access }
  end

  def decision_confidence
    meta.dig("status_classification", "confidence")
  end

  def decision_confidence_label
    { "high" => "高", "medium" => "中", "low" => "低" }[decision_confidence]
  end

  # ── 驗收/監控用中繼資料（管理頁不用查資料庫就能看到）──────────────
  def ai_api_success?
    meta.key?("ai_api_success") ? meta["ai_api_success"] : status == "success"
  end

  def quality_check
    meta["quality_check"]
  end

  def quality_passed?
    quality_check.present? && quality_check["passed"] == true
  end

  # true＝有品質檢查結果但沒通過；false＝通過或本來就沒有（例如AI失敗，
  # 沒有ai_report可以檢查）。畫面用這個決定要不要顯示「需要檢查」badge。
  def quality_needs_review?
    quality_check.present? && !quality_passed?
  end

  def data_completeness_score
    metrics.dig("data_gaps", "completeness_score")
  end

  def missing_fields
    Array(meta["missing_fields"])
  end

  def retried?
    meta["retried"] == true
  end

  # 品質未過（quality_check沒通過）或內容驗證沒過（invalid_response）都要
  # 擋掉「這份可以直接拿去做決策」的觀感——畫面用這個決定要不要在最上方
  # 顯示醒目警示。
  def needs_review_banner?
    status == "invalid_response" || quality_needs_review?
  end

  # ── 背景重新產生（見 WeeklyBriefingRegenerationJob）────────────────
  def regenerating?
    regeneration_started_at.present? && regeneration_started_at > REGENERATION_TIMEOUT.ago
  end
end
