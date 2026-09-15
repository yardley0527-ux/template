# frozen_string_literal: true

# 每週營運檢討報告：WeeklyBriefingService 生成後落地一份（週一為 week_start），
# 首頁與 /weekly_briefings 只讀已落地的資料——不即時呼叫 API，可回溯、成本可控。
# 跟 DailyBriefing 是同一種設計（見 app/services/daily_briefing_service.rb）。
class WeeklyBriefing < ApplicationRecord
  STATUSES = %w[pending success failed].freeze

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
end
