# frozen_string_literal: true

module NotificationRules
  # M. livestream_performance_drop — D+1/D+3 表現比較，取代 event_attention
  # 原本單一「低於前3場平均50%」的判定。比較基準優先順序：①同主推產品最近3場
  # ②同活動類型（沒有活動類型欄位可用，跳過這一層，直接退回）③最近3-5場整體。
  # 只用「最近3場整體」實作①③（②因為沒有 campaign/type 欄位無法區分，退回③）。
  #
  # dedup_key 用 (livestream_id, offset) 固定——一旦 offset(=D+1 or D+3) 達到就
  # 開始回傳，並持續回傳到 RETENTION_DAYS 上限，數字本身穩定不變（同一段
  # order_date 區間查詢結果不會因為「今天是哪一天」而改變），這樣卡片不會
  # 因為日曆往前走就被引擎誤判成「條件消失」而自動關閉——同時仍然只在
  # D+1／D+3 那天才「第一次」出現。
  class LivestreamPerformanceDrop
    OFFSETS = { 1 => "d1", 3 => "d3" }.freeze
    RETENTION_DAYS = 30
    COMPARISON_COUNT = NotificationRules::Thresholds::COMPARISON_LIVESTREAM_COUNT
    COMPARISON_MIN_COUNT = NotificationRules::Thresholds::COMPARISON_MIN_COUNT
    MIN_BASELINE_REVENUE = NotificationRules::Thresholds::DROP_MIN_BASELINE_REVENUE
    MIN_BASELINE_ORDERS = NotificationRules::Thresholds::DROP_MIN_BASELINE_ORDERS
    P2_MIN_ABSOLUTE_GAP = NotificationRules::Thresholds::DROP_P2_MIN_ABSOLUTE_REVENUE_GAP

    def self.call
      new.call
    end

    def call
      eligible_livestreams.flat_map { |ls| OFFSETS.filter_map { |offset, key| build(ls, offset, key) } }
    end

    private

    def eligible_livestreams
      Livestream.where(date: (Date.current - RETENTION_DAYS)..(Date.current - 1))
    end

    def build(livestream, offset, key)
      return nil if (Date.current - livestream.date).to_i < offset

      comparison_group = prior_livestreams(livestream, COMPARISON_COUNT)
      if comparison_group.size < COMPARISON_MIN_COUNT
        return insufficient_data_card(livestream, offset, key, comparison_group.size)
      end

      current = LivestreamAttribution.new(livestream, window_days: offset)
      priors = comparison_group.map { |ls| LivestreamAttribution.new(ls, window_days: offset) }
      prior_avg_revenue = priors.sum(&:revenue) / priors.size
      prior_avg_orders  = priors.sum(&:orders).to_f / priors.size

      return nil if prior_avg_revenue < MIN_BASELINE_REVENUE || prior_avg_orders < MIN_BASELINE_ORDERS

      pct = ((current.revenue - prior_avg_revenue) / prior_avg_revenue * 100).round(1)
      return nil if pct >= NotificationRules::Thresholds::DROP_P3_HIGH_PCT # 沒有明顯下降，不出卡

      absolute_gap = (prior_avg_revenue - current.revenue).to_i
      possible_causes = possible_causes_for(livestream, offset)
      confidence_lowered = possible_causes.any?

      priority = priority_for(pct: pct, absolute_gap: absolute_gap, confidence_lowered: confidence_lowered)

      drop_card(livestream, offset, key, current, prior_avg_revenue, prior_avg_orders, pct, absolute_gap,
                possible_causes, priority, comparison_group.size)
    end

    def drop_card(livestream, offset, key, current, prior_avg_revenue, prior_avg_orders, pct, absolute_gap,
                   possible_causes, priority, comparison_size)
      cause_note = possible_causes.any? ? "（可能原因：#{possible_causes.join('、')}，資料可信度較低）" : ""
      {
        notification_key: "livestream_performance_drop_#{key}", kind: "alert",
        severity: priority == "P1" ? "warning" : "opportunity", priority: priority,
        title: "#{livestream.date} 直播 D+#{offset} 營收較近#{comparison_size}場均值低 #{pct.abs}%#{cause_note}",
        message: "本場 D+#{offset} NT$#{current.revenue.to_i}，前#{comparison_size}場均值 NT$#{prior_avg_revenue.to_i}" \
                 "（差額 NT$#{absolute_gap}）",
        impact_summary: "D+#{offset}累積表現明顯低於近期同期比較基準#{cause_note}。",
        recommended_action: possible_causes.any? ? "先確認：#{possible_causes.join('、')}，排除後再判斷是否為真的銷售力下降。" : "建立直播檢討事項，記錄可能原因。",
        subject_type: "livestream", subject_id: livestream.id.to_s,
        metadata: {
          livestream_date: livestream.date.to_s, offset: offset, revenue: current.revenue.to_i,
          orders: current.orders, buyers: current.buyers, new_buyers: current.new_buyers,
          prior_avg_revenue: prior_avg_revenue.to_i, prior_avg_orders: prior_avg_orders.round(1),
          pct: pct, absolute_gap: absolute_gap, comparison_livestream_ids: comparison_group_ids(livestream),
          possible_causes: possible_causes, data_sufficient: true
        },
        deduplication_key: "livestream_performance_drop_#{key}:livestream:#{livestream.id}"
      }
    end

    def insufficient_data_card(livestream, offset, key, available_count)
      return nil if available_count.zero? # 完全沒有比較基準時，連「資料不足」卡都不出，避免噪音

      {
        notification_key: "livestream_performance_drop_#{key}", kind: "alert", severity: "info", priority: "P3",
        title: "#{livestream.date} 直播 D+#{offset}：可比較場次不足，暫不判定",
        message: "只有 #{available_count} 場可比較（需要至少 #{COMPARISON_MIN_COUNT} 場），先列資訊摘要",
        impact_summary: "比較基準不足，任何百分比判定都不可靠，先不下結論。",
        recommended_action: "累積更多場次後，比較才有意義。",
        subject_type: "livestream", subject_id: livestream.id.to_s,
        metadata: { livestream_date: livestream.date.to_s, offset: offset, available_comparison_count: available_count,
                    data_sufficient: false },
        deduplication_key: "livestream_performance_drop_#{key}:livestream:#{livestream.id}"
      }
    end

    # 呼叫前已過濾 pct < DROP_P3_HIGH_PCT（-20%），所以這裡一定至少是 P3 等級的下降。
    #   <= -50%：資料完整＋基期足夠＋非缺貨/匯入異常 → P1；否則（資料可信度較低或差額太小）降到 P2
    #   -50% ~ -35%：絕對差額達門檻 → P2；否則 P3
    #   -35% ~ -20%：P3（觀察）
    def priority_for(pct:, absolute_gap:, confidence_lowered:)
      t = NotificationRules::Thresholds
      if pct <= t::DROP_P2_LOW_PCT
        absolute_gap >= P2_MIN_ABSOLUTE_GAP && !confidence_lowered ? "P1" : "P2"
      elsif pct <= t::DROP_P3_LOW_PCT
        absolute_gap >= P2_MIN_ABSOLUTE_GAP ? "P2" : "P3"
      else
        "P3"
      end
    end

    # 主推商品缺貨、直播時間顯著較短（無時長欄位可查，跳過）、匯入延遲，都會
    # 降低這次判定的可信度——只檢查真的有資料可查的兩項，不假裝檢查了時長。
    def possible_causes_for(livestream, offset)
      causes = []
      out_of_stock_products = livestream.product_keys.select do |key|
        CrmProduct.find_by(key: key)&.availability_status == "out_of_stock"
      end
      causes << "主推商品缺貨（#{out_of_stock_products.join('、')}）" if out_of_stock_products.any?

      # 匯入時間要晚於這個比較窗口（D+offset）的區間終點，資料才算完整覆蓋。
      last_import = ImportRun.where(kind: "paid_orders_workbook").maximum(:finished_at)
      window_end = LivestreamAttribution.window_range(livestream.date, offset).end
      causes << "訂單匯入延遲，資料可能未涵蓋完整窗口" if last_import.nil? || last_import < window_end

      causes
    end

    def prior_livestreams(livestream, count)
      Livestream.where("date < ?", livestream.date).order(date: :desc).limit(count).to_a
    end

    def comparison_group_ids(livestream)
      prior_livestreams(livestream, COMPARISON_COUNT).map(&:id)
    end
  end
end
