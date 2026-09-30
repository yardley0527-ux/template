# frozen_string_literal: true

module NotificationRules
  # H. black_overdue — 黑卡客人「該回購但還沒回來」，一個產品一張卡。
  #
  # 跟 customer_overdue 的差別：那張是「高價值客（黑/金卡、大單）逾期 1–14 天」，
  # 只留最新鮮的級距；這張只看黑卡，逾期範圍放寬到 1–60 天（Thresholds::BLACK_OVERDUE_DAYS），
  # 老闆要看的是「黑卡該回來卻沒回來」的完整名單，不是只有剛逾期的那幾天。
  # 展開後的名單（NotificationCustomerListService）會即時重查訂單、依累積消費由高到低排序。
  #
  # 產品範圍沿用 customer_overdue：穀胱甘肽是波段補貨型產品，固定天數的逾期
  # 判斷不成立，整個排除；缺貨／停售產品也不出卡（客人買不到不算沒回來）。
  class BlackOverdue
    RANGE = NotificationRules::Thresholds::BLACK_OVERDUE_DAYS
    MEMBERSHIP_LEVELS = %w[黑卡].freeze
    EXCLUDED_PRODUCTS = NotificationRules::CustomerOverdue::EXCLUDED_PRODUCTS
    ESTIMATED_CYCLE_PRODUCTS = NotificationRules::CustomerOverdue::ESTIMATED_CYCLE_PRODUCTS
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    # 哪些產品要看黑卡逾期名單（排除穀胱甘肽與缺貨／停售產品）；名單頁（BlackOverdueList）共用。
    def self.eligible_product_keys
      (JourneyProducts::PRODUCTS.keys - EXCLUDED_PRODUCTS).reject do |key|
        crm_product = NotificationRules::ProductKeyMapping.crm_product_for(key)
        crm_product && %w[out_of_stock discontinued].include?(crm_product.availability_status)
      end
    end

    # NotificationCustomerListService 展開名單用的查詢條件。
    def self.query_for(product_key)
      { table: "crm_customer_product_trackings", product_key: product_key,
        overdue_days_from: RANGE.begin, overdue_days_to: RANGE.end,
        membership_level_in: MEMBERSHIP_LEVELS }
    end

    def call
      self.class.eligible_product_keys.filter_map { |key| build_for_product(key) }
    end

    private

    def build_for_product(product_key)
      rows = overdue_black_customers(product_key)
      return nil if rows.empty?

      label = JourneyProducts::PRODUCTS.fetch(product_key)[:label]
      estimate_tag = ESTIMATED_CYCLE_PRODUCTS.include?(product_key) ? "（週期為估計值）" : ""
      total = rows.size

      {
        notification_key: "black_overdue_#{product_key}", kind: "opportunity", severity: "warning",
        priority: "P2",
        title: "#{label}#{estimate_tag}黑卡逾期未回購：#{total} 位",
        message: "黑卡客人已逾期 #{RANGE.begin}–#{RANGE.end} 天還沒回購#{label}，名單依累積消費由高到低排序",
        impact_summary: "#{total} 位黑卡客人該回購#{label}卻還沒回來，逾期越久轉換率通常越低。",
        recommended_action: "從累積消費最高的開始聯繫，處理完可直接建立客服任務。",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, total_count: total, band: "#{RANGE.begin}_#{RANGE.end}",
          estimated_cycle: ESTIMATED_CYCLE_PRODUCTS.include?(product_key),
          sample_shopline_customer_ids: rows.first(METADATA_SAMPLE_SIZE),
          query: self.class.query_for(product_key)
        },
        deduplication_key: "black_overdue:journey_product:#{product_key}"
      }
    end

    # 一次 SQL 撈出這個產品逾期範圍內的黑卡客人；同一位客人（同 email）只算一次，
    # 累積消費高的排前面，讓抽樣 id 也是最重要的那幾位。
    def overdue_black_customers(product_key)
      conn = ActiveRecord::Base.connection
      today = Date.current
      levels = MEMBERSHIP_LEVELS.map { |l| conn.quote(l) }.join(",")

      sql = <<~SQL
        SELECT DISTINCT ON (lower(trim(t.email))) sc.id AS customer_id, COALESCE(sc.total_amount, 0) AS total_amount
        FROM crm_customer_product_trackings t
        JOIN shopline_customers sc ON lower(trim(sc.email)) = lower(trim(t.email))
        WHERE t.product_key = #{conn.quote(product_key)}
          AND sc.membership_level IN (#{levels})
          AND t.expected_return_date BETWEEN #{conn.quote(today - RANGE.end)} AND #{conn.quote(today - RANGE.begin)}
        ORDER BY lower(trim(t.email)), sc.total_amount DESC NULLS LAST
      SQL
      conn.select_all(sql).to_a.sort_by { |r| -r["total_amount"].to_f }.map { |r| r["customer_id"] }
    end
  end
end
