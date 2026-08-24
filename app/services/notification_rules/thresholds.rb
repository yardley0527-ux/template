# frozen_string_literal: true

module NotificationRules
  # 所有規則的可調閾值集中在這裡，不要散落在各規則檔案裡硬編碼——
  # 方便測試（RSpec/Minitest 可以 stub_const 覆寫）跟未來調整。
  module Thresholds
    # ── customer_runout（即將用完）分級 ──
    RUNOUT_P1_DAYS = (0..3).freeze
    RUNOUT_P2_DAYS = (4..7).freeze

    # ── customer_overdue（逾期未回購）分段 ──
    OVERDUE_BANDS = [
      { key: "1_14",  range: (1..14) },
      { key: "15_30", range: (15..30) },
      { key: "31_60", range: (31..60) },
      { key: "61_90", range: (61..90) },
      { key: "90_plus", range: (91..Float::INFINITY) }
    ].freeze

    # ── livestream_schedule_gap（直播週期缺口） ──
    LIVESTREAM_CYCLE_DAYS = 14
    LIVESTREAM_GAP_P2_AFTER_DAYS = 14
    LIVESTREAM_GAP_P1_AFTER_DAYS = 17
    LIVESTREAM_LOOKAHEAD_DAYS = 7

    # ── livestream_performance_drop（直播後表現比較） ──
    DROP_P3_LOW_PCT  = -35.0 # 低 20%-35%：介於 P3 下限與上限之間
    DROP_P3_HIGH_PCT = -20.0
    DROP_P2_LOW_PCT  = -50.0
    DROP_P1_LOW_PCT  = -100.0 # 低超過 50% 都可能是 P1，實際門檻另外判斷資料完整度
    DROP_MIN_BASELINE_REVENUE = 30_000 # 比較基準太小，百分比會失真
    DROP_MIN_BASELINE_ORDERS = 5
    DROP_P2_MIN_ABSOLUTE_REVENUE_GAP = 15_000
    COMPARISON_LIVESTREAM_COUNT = 3
    COMPARISON_MIN_COUNT = 2 # 資料不足門檻：可比較場次少於這個數就標記「資料不足」

    # ── livestream_review_due（賽後檢討待完成） ──
    REVIEW_DUE_P2_AFTER_DAYS = 3
    REVIEW_DUE_P1_AFTER_DAYS = 5

    # ── livestream_preparation（直播前檢查） ──
    PREP_T_MINUS_DAYS = [3, 1].freeze

    # ── high_spender_no_second window（首購金額門檻/天數，沿用既有規則） ──
    HIGH_SPENDER_WINDOW_DAYS = (30..90).freeze
  end
end
