# frozen_string_literal: true

module NotificationRules
  # 所有規則的可調閾值集中在這裡，不要散落在各規則檔案裡硬編碼——
  # 方便測試（RSpec/Minitest 可以 stub_const 覆寫）跟未來調整。
  module Thresholds
    # ── customer_runout（即將用完）分級 ──
    RUNOUT_P1_DAYS = (0..3).freeze
    RUNOUT_P2_DAYS = (4..7).freeze

    # ── customer_overdue（逾期未回購）分段 ──
    # 8/25 使用者要求：待處理清單只留最新鮮的 0-14 天級距，逾期越久的名單轉換率
    # 越低、優先度也低，不用一直佔待處理清單版面；15 天以上的追蹤資料本身還在
    # （crm_customer_product_trackings），只是不再主動產生通知卡片。
    OVERDUE_BANDS = [
      { key: "1_14", range: (1..14) }
    ].freeze

    # ── 高價值客判定（黑/金卡 或 末單金額門檻 或 末單為大組數）──
    # 8/24 使用者要求：customer_overdue 的「待維護名單」只留高價值客，
    # 一般客不再排進待處理名單（但仍算在 general_count 供觀察）。
    # 同日補充：曾買大組數（一次多瓶/多盒）的客人也算高價值，不限卡別——
    # 卡別是「歷史累積消費」的落後指標，大組數是「這次就砸了一筆」的即時訊號，
    # 卡別還沒升上去但單次投入已經很高的客人不該被漏掉。
    HIGH_VALUE_MEMBERSHIP = %w[黑卡 金卡].freeze
    HIGH_VALUE_AMOUNT = 30_000
    HIGH_VALUE_BOTTLES = 6 # 沿用魚油/膠原等產品「6+1」組數開始送贈品的級距，視為大組數起點

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
