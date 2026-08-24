# frozen_string_literal: true

module NotificationRules
  # G. vip_silent — 黑卡/金卡 silent for 90+ days, tiered by priority
  # (90-179=P2, 180+=P1 — card tier is a sort-priority signal within the
  # expanded list, not a priority override on its own). One aggregate card
  # per tier per week (dedup_key includes ISO week so it naturally opens a
  # fresh cycle weekly rather than staying open forever).
  #
  # 客服每日產能沒有固定設定值可讀（CrmLivestreamOutreachScheduler 的
  # daily_cap 是每次排程時手動輸入的表單參數，不是常駐設定），所以「今日可
  # 處理」這格顯示「資料不足」而不是編造一個數字——已排程／未排程仍然可以
  # 透過既有的 CrmLivestreamOutreachTask／CrmCustomerProductCycle 交叉比對
  # 算出來，是真數字。
  class VipSilent
    TIERS = [
      { key: "90_179", range: (90..179), priority: "P2" },
      { key: "180_plus", range: (180..Float::INFINITY), priority: "P1" }
    ].freeze
    HIGH_CARD_LEVELS = %w[黑卡 金卡].freeze
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      TIERS.filter_map { |tier| build_for_tier(tier) }
    end

    private

    def build_for_tier(tier)
      rows = silent_customers(tier[:range])
      return nil if rows.empty?

      week_start = Date.current.beginning_of_week
      black_count = rows.count { |r| r["membership_level"] == "黑卡" }
      gold_count  = rows.size - black_count
      label = tier[:key] == "90_179" ? "90–179 天" : "180 天以上"

      identity_keys = rows.filter_map { |r| r["identity_key"] }
      scheduled_keys = existing_task_or_followup_identity_keys(identity_keys)
      scheduled_count = identity_keys.count { |k| scheduled_keys.include?(k) }
      unscheduled_count = rows.size - scheduled_count

      {
        notification_key: "vip_silent_#{tier[:key]}", kind: "opportunity", severity: tier[:priority] == "P1" ? "warning" : "opportunity",
        priority: tier[:priority],
        title: "黑/金卡沉睡 #{label}：#{rows.size} 位（黑卡 #{black_count}／金卡 #{gold_count}）",
        message: "已排程 #{scheduled_count} 位／未排程 #{unscheduled_count} 位；今日可處理人數需在直播排程頁面依當日客服產能另行指定（資料不足，非固定設定）",
        impact_summary: "#{rows.size} 位高卡別客戶已#{label}沒有下單，流失風險持續升高。",
        recommended_action: "從未排程的#{unscheduled_count}位裡優先挑黑卡、消費金額高的建立客服任務。",
        subject_type: "vip_silent_batch", subject_id: "#{tier[:key]}:#{week_start}",
        metadata: {
          tier: tier[:key], count: rows.size, black_count: black_count, gold_count: gold_count,
          scheduled_count: scheduled_count, unscheduled_count: unscheduled_count,
          daily_capacity_available: nil, # 資料不足：沒有固定客服每日產能設定
          week_start: week_start.to_s,
          sample_shopline_customer_ids: rows.filter_map { |r| r["customer_id"] }.first(METADATA_SAMPLE_SIZE),
          query: { table: "customer_purchase_summaries+shopline_customers", membership_level_in: HIGH_CARD_LEVELS,
                   silent_days_from: tier[:range].begin, silent_days_to: (tier[:range].end.finite? ? tier[:range].end : nil) }
        },
        deduplication_key: "vip_silent_#{tier[:key]}:vip_silent_batch:#{week_start}"
      }
    end

    # 用同一套 identity_key 格式（mobile_phone 優先、否則 email）跟
    # CrmLivestreamOutreachTask（未完成）／CrmCustomerProductCycle（有進行中
    # follow_up_status）交叉比對，避免對已經排過的人重複建卡。
    def existing_task_or_followup_identity_keys(identity_keys)
      return Set.new if identity_keys.empty?

      from_tasks = CrmLivestreamOutreachTask.where(identity_key: identity_keys, status: "pending").pluck(:identity_key)
      from_cycles = CrmCustomerProductCycle.where(identity_key: identity_keys)
                                            .where.not(follow_up_status: nil)
                                            .where.not(follow_up_status: "repurchased")
                                            .pluck(:identity_key)
      (from_tasks + from_cycles).to_set
    end

    def silent_customers(range)
      levels = HIGH_CARD_LEVELS.map { |l| ActiveRecord::Base.connection.quote(l) }.join(",")
      upper_clause = range.end.finite? ? "AND (CURRENT_DATE - cps.last_order_date::date) <= #{range.end}" : ""

      sql = <<~SQL
        SELECT sc.id AS customer_id, sc.membership_level, cps.identity_key
        FROM shopline_customers sc
        JOIN customer_purchase_summaries cps
          ON cps.identity_key = COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(sc.email)))
        WHERE sc.membership_level IN (#{levels})
          AND (CURRENT_DATE - cps.last_order_date::date) >= #{range.begin}
          #{upper_clause}
      SQL
      ActiveRecord::Base.connection.select_all(sql).to_a
    end
  end
end
