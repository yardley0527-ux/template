# frozen_string_literal: true

module Marketing
  # 給 AI 的分析快照：只放程式算好的彙總數字（metric）、可引用的客群（segment）、產品、有效優惠與來源設定。
  # 不含姓名、電話、Email、私訊原文、健康資料。AI 只能引用這裡的 id，後端（CardValidator）逐一檢查。
  class SnapshotBuilder
    SOURCE_LIMIT = 12
    PROMOTION_FRESH_DAYS = 14

    def initialize(now: Time.current)
      @now = now
      @segments = Segments.new(now: now)
      @status = DataStatus.new(now: now)
    end

    def call
      metrics = []
      add = ->(id, label, value, unit = "人") { metrics << { "id" => id, "label" => label, "value" => value, "unit" => unit } }
      h = @status.to_h

      add.call("m.subs.total", "ManyChat 訂閱者", h[:subscribers])
      add.call("m.subs.verified", "已確認身分", h[:verified])
      add.call("m.subs.candidate", "候選待確認", h[:candidate])
      add.call("m.subs.unmatched", "未比對", h[:unmatched])
      add.call("m.subs.verified_pct", "已確認身分比例", h[:verified_rate] && (h[:verified_rate] * 100).round(1), "%")
      add.call("m.flow_events.total", "Flow 回傳事件數", h[:flow_events], "筆")

      perf = SourcePerformance.new(from: (@now - 30.days).to_date, to: @now.to_date, now: @now)
      add.call("m.src.all.people", "最近 30 天互動人數（去重）", perf.total.people)
      perf.rows.first(SOURCE_LIMIT).each_with_index do |r, i|
        base = "m.src.#{i + 1}"
        add.call("#{base}.people", "#{r.label}・30 天互動人數", r.people)
        add.call("#{base}.verified", "#{r.label}・已確認身分", r.verified)
        add.call("#{base}.matured", "#{r.label}・已滿 7 天觀察期的已確認者（下單率分母）", r.matured)
        next unless r.sample_ok?

        add.call("#{base}.converted", "#{r.label}・7 天內下單人數", r.converted)
        add.call("#{base}.rate_pct", "#{r.label}・7 天內下單率", (r.rate * 100).round(1), "%")
      end

      {
        "rule_version" => Segments::RULE_VERSION,
        "generated_at" => @now.iso8601,
        "data_as_of" => { "manychat_last_sync" => h[:manychat_last_success_at]&.iso8601, "orders_to" => h[:orders_to]&.iso8601,
                          "manychat_tracking_from" => h[:manychat_sync_started_on]&.iso8601 },
        "metrics" => metrics.reject { |m| m["value"].nil? },
        "segments" => segment_entries,
        "products" => products,
        "promotions" => promotions,
        "sources" => ManychatSource.where(active: true).order(:key).map { |s|
          { "key" => s.key, "name" => s.name, "content_type" => s.content_type, "topic" => s.topic, "product_keys" => s.product_keys }
        },
        "data_gaps" => @status.gaps,
        "policies" => [
          "未比對或候選的人購買狀態未知，不能寫成沒買過或新客",
          "IG 私訊窗口與各渠道行銷同意狀態一律未知，管道只能寫「發送前待確認」",
          "沒有成本資料，不能說哪個活動比較賺；觀察期內關聯訂單金額不是增量營收"
        ]
      }
    end

    private

    def segment_entries
      specs = [
        ["recent_interactors", { "days" => 7 }], ["recent_interactors", { "days" => 30 }],
        ["recent_interactors", { "days" => 14, "identity" => "unmatched" }],
        ["interacted_not_ordered", { "days" => 14 }], ["never_purchased", { "days" => 30 }],
        ["repurchase_due", { "ahead" => 14 }], ["repurchase_due", { "ahead" => 14, "manychat_only" => true }]
      ]
      mapped_products = ManychatSource.where(active: true).pluck(:product_keys).flatten.uniq
      mapped_products.each { |k| specs << ["product_source_interest", { "product_key" => k, "days" => 14 }] }
      ManychatEvent.where(event_type: %w[info_requested offer_requested purchase_help_requested], event_time: (@now - 14.days)..@now)
                   .distinct.pluck(Arel.sql("properties->>'product_key'")).compact.each do |k|
        specs << ["product_explicit_request", { "product_key" => k, "days" => 14 }]
      end

      specs.each_with_index.map do |(key, params), i|
        r = @segments.build(key, params)
        { "id" => "seg.#{i + 1}", "key" => key, "params" => r.params, "label" => r.label, "conditions" => r.conditions,
          "count" => r.count, "breakdown" => r.breakdown, "reliability" => r.reliability }
      end
    end

    def products
      CrmProduct.where(status: "confirmed", include_in_analysis: true).order(:key).map do |p|
        { "key" => p.key, "label" => p.label, "availability" => p.availability_status }
      end
    end

    # 最近 14 天爬到、確實有折扣的最新一筆；沒有就是空的，AI 不得自創優惠
    def promotions
      ProductPromotionSnapshot.where(scraped_at: (@now - PROMOTION_FRESH_DAYS.days)..@now).where("discount_pct > 0")
                              .order(scraped_at: :desc).group_by(&:product_key).values.map(&:first).map do |p|
        { "id" => p.id, "product_key" => p.product_key, "regular_price" => p.regular_price, "sale_price" => p.sale_price,
          "discount_pct" => p.discount_pct.to_f, "scraped_at" => p.scraped_at.iso8601 }
      end
    end
  end
end
