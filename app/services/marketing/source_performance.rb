# frozen_string_literal: true

module Marketing
  # 來源表現：每個來源的互動人數、已確認身分人數與覆蓋率、觀察期滿 7 天的人裡有多少人下單。
  #
  # - 下單率分母＝已確認身分、而且從他在這個來源的第一次互動起，訂單資料已涵蓋滿 7 天的人。
  #   還沒滿 7 天的人另外列，不混進轉換率。
  # - 金額叫「觀察期內關聯訂單金額」：只是互動後 7 天內的已付款訂單，不是增量營收，也沒扣退款。
  # - 同一人、同一張訂單可能出現在多個來源，合計列用去重後的人數與訂單，不是各列相加。
  # - 已滿觀察期的人少於 MIN_SAMPLE 時標「樣本不足」，不排名。
  class SourcePerformance
    OBSERVE_DAYS = 7
    MIN_SAMPLE = 20

    Row = Struct.new(:source, :label, :mapped, :people, :verified, :matured, :immature, :converted,
                     :linked_amount, :reliable_share, keyword_init: true) do
      def coverage = people.zero? ? nil : verified.fdiv(people)
      def rate = matured.zero? ? nil : converted.fdiv(matured)
      def sample_ok? = matured >= MIN_SAMPLE
    end

    attr_reader :from, :to

    def initialize(from:, to:, now: Time.current)
      @from = from
      @to = to
      @now = now
      @segments = Segments.new(now: now)
      @orders_to = DataStatus.new(now: now).order_range.last
      @mapped = ManychatSource.index_by_raw_name
    end

    def rows
      @rows ||= begin
        by_source.map { |label, group| build_row(label, group) }.sort_by { |r| -r.people }
      end
    end

    # 去重合計
    def total
      @total ||= build_row("（合計・去重）", interactions)
    end

    def orders_to = @orders_to

    private

    def interactions
      @interactions ||= ManychatInteraction.includes(:manychat_subscriber)
                                           .where(interacted_at: @from.beginning_of_day..@to.end_of_day).to_a
    end

    def by_source
      interactions.group_by { |i| @segments.source_label(i.source) }
    end

    def build_row(label, group)
      firsts = group.group_by(&:manychat_subscriber).transform_values { |is| is.map(&:interacted_at).min }
      verified = firsts.select { |sub, _| sub.verified? }
      cutoff = @orders_to && (@orders_to - OBSERVE_DAYS).end_of_day
      matured = verified.select { |_, at| cutoff && at <= cutoff }
      orders = OrderIndex.new(matured.keys.map(&:shopline_customer_id))
      linked = matured.flat_map do |sub, at|
        orders.orders_for(sub.shopline_customer_id).select { |o| o.at >= at && o.at < at + OBSERVE_DAYS.days }.map { |o| [sub.id, o] }
      end
      raw = group.first&.source.to_s
      setting = @mapped[raw]
      Row.new(source: setting ? setting.key : raw.presence || Manychat::LeadReport::NO_SOURCE, label: label, mapped: !setting.nil?,
              people: firsts.size, verified: verified.size, matured: matured.size,
              immature: verified.size - matured.size, converted: linked.map(&:first).uniq.size,
              linked_amount: linked.map(&:last).uniq(&:number).sum(&:amount),
              reliable_share: group.empty? ? nil : group.count(&:source_reliable?).fdiv(group.size))
    end
  end
end
