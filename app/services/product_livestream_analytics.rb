# frozen_string_literal: true

# 方案 B PR4：共用產品直播分析引擎，供 LivestreamProductAnalysisController 使用。
# 取代 5 個各自為政的舊 controller（app/controllers/concerns/product_livestream_analysis.rb
# 的 ALL_EVENTS/note 字串比對、益生菌的寫死日期）——場次來源改讀
# Livestream.product_keys（GIN 相容 array contains），「本場銷售產品」不再靠字串猜。
#
# 所有買家/營收數字走 LivestreamAttribution（推定歸因，Asia/Taipei D0~D+window_days
# 半開區間），卡別一律是「目前」membership_level（非直播當時）。
class ProductLivestreamAnalytics
  include MembershipLevels

  RETURN_WINDOW_DAYS   = 90  # 未回購名單：逾期上限（沿用舊 concern 慣例）
  ACTIVE_LOOKBACK_DAYS = 180 # 未回購名單：近多久內仍算「活躍」

  def initialize(product_key)
    @product_key = product_key
    @crm_product = CrmProduct.find_by(key: product_key)
  end

  attr_reader :product_key, :crm_product

  def valid_product?
    crm_product.present?
  end

  def events
    @events ||= Livestream.where("product_keys @> ARRAY[?]::varchar[]", product_key).reorder(:date)
  end

  def past_events
    @past_events ||= events.select { |e| e.date <= Date.current }
  end

  def latest_event
    past_events.last
  end

  # 每場：推定歸因買家 email 集合（只算 email 非空）＋摘要指標。
  def event_summaries
    @event_summaries ||= past_events.map do |ls|
      attribution = LivestreamAttribution.new(ls)
      emails = attribution.order_rows.filter_map { |r| r[:email] }.uniq.to_set
      { livestream: ls, emails: emails, buyers: emails.size,
        revenue: attribution.revenue, orders: attribution.orders }
    end
  end

  def cross_event_stats
    event_summaries.each_with_index.map do |s, i|
      prev = i.positive? ? event_summaries[i - 1] : nil
      overlap = prev ? (prev[:emails] & s[:emails]).size : nil
      {
        livestream: s[:livestream], buyers: s[:buyers], revenue: s[:revenue], orders: s[:orders],
        aov: s[:buyers].positive? ? (s[:revenue] / s[:buyers]).round : 0,
        return_count: overlap,
        return_rate: (prev && prev[:buyers].positive?) ? (overlap.to_f / prev[:buyers] * 100).round(1) : nil
      }
    end
  end

  def iron_fans
    return [] if event_summaries.size < 2

    common_emails = event_summaries.map { |s| s[:emails] }.reduce(:&)
    customers_for(common_emails.to_a).map { |c| { customer: c, attended_count: event_summaries.size } }
                                     .sort_by { |r| sort_key(r[:customer]) }
  end

  def high_risk_lost
    return [] if event_summaries.size < 2

    latest_emails = event_summaries.last[:emails]
    prior_emails  = event_summaries[0..-2].flat_map { |s| s[:emails].to_a }.uniq
    lost = prior_emails - latest_emails.to_a
    customers_for(lost, levels: %w[黑卡 金卡]).map do |c|
      attended = event_summaries[0..-2].select { |s| s[:emails].include?(c.email) }
                                        .map { |s| s[:livestream].date.strftime("%Y/%m/%d") }
      { customer: c, attended_labels: attended }
    end.sort_by { |r| sort_key(r[:customer]) }
  end

  def missing_customers
    return [] if event_summaries.size < 2

    all_prior_emails = event_summaries[0..-2].flat_map { |s| s[:emails].to_a }.uniq
    missing_emails = all_prior_emails - event_summaries.last[:emails].to_a
    build_snapshot_rows(missing_emails)
  end

  def expiring_soon
    all_emails = event_summaries.flat_map { |s| s[:emails].to_a }.uniq
    return [] if all_emails.empty?

    snapshots = CustomerProductSnapshotService.call(emails: all_emails, product_key: product_key, reference_date: Date.current)
    customers_for(snapshots.keys).filter_map do |c|
      snap = snapshots[c.email]
      next unless snap
      next unless snap.days_until_return.between?(-7, 21)

      { customer: c, days_left: snap.days_until_return, last_product: snap.last_product_name, last_date: snap.last_order_date }
    end.sort_by { |r| [r[:days_left], -MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0)] }
  end

  def level_attendance
    return [] unless latest_event

    MembershipLevelStatsService.call(event_emails: event_summaries.last[:emails].to_a)
  end

  # 場次窗內，可被系統辨識商品名稱的訂單列比例——不是「這張訂單一定屬於本產品」
  # 的精確率，是「本產品直播檔期內，系統對商品名稱的整體辨識程度」。
  def recognition_coverage
    return nil if past_events.empty?

    total = 0
    recognized = 0
    past_events.each do |ls|
      range = LivestreamAttribution.window_range(ls.date, ls.window_days)
      scope = ShoplineOrder.where(order_date: range)
      total += scope.count
      recognized += scope.joins(
        "INNER JOIN product_name_mappings pnm ON pnm.raw_name = shopline_orders.product_name AND pnm.mapping_status = 'confirmed_alias'"
      ).count
    end
    return nil if total.zero?

    (recognized.to_f / total * 100).round(1)
  end

  def bundle_components_decomposed?
    ProductMappingComponent.exists?
  end

  # 參數化的交叉銷售：本產品場次窗內曾買過 target_key，但窗口結束後未再買
  # target_key 的黑金卡買家（例如全能→美白）。
  def cross_sell(target_key:)
    return [] if event_summaries.empty?

    windows = past_events.map { |ls| LivestreamAttribution.window_range(ls.date, ls.window_days) }
    target_email_sets = windows.map do |range|
      ProductNameResolver.orders_for(target_key).where(order_date: range)
                          .where.not(email: [nil, ""]).distinct.pluck(:email).to_set
    end
    ever_bought_target = target_email_sets.reduce(:|) || Set.new
    return [] if ever_bought_target.empty?

    last_window_end = windows.last.end
    rebought_after = ProductNameResolver.orders_for(target_key)
                                        .where("order_date >= ?", last_window_end)
                                        .where.not(email: [nil, ""]).distinct.pluck(:email).to_set
    lapsed = ever_bought_target - rebought_after

    source_counts = event_summaries.each_with_object(Hash.new(0)) { |s, h| s[:emails].each { |e| h[e] += 1 } }
    customers_for(lapsed.to_a, levels: %w[黑卡 金卡]).map do |c|
      { customer: c, source_event_count: source_counts[c.email] || 0 }
    end.sort_by { |r| sort_key(r[:customer]) }
  end

  private

  def sort_key(customer)
    [-MEMBERSHIP_RANK.fetch(customer.membership_level, 0), -customer.total_amount.to_f]
  end

  def customers_for(emails, levels: TARGET_MEMBERSHIPS)
    return [] if emails.empty?

    ShoplineCustomer.where(email: emails, membership_level: levels)
                    .select(:id, :full_name, :email, :mobile_phone, :membership_level, :instagram_account, :total_amount)
  end

  def build_snapshot_rows(emails)
    return [] if emails.empty?

    today = Date.current
    snapshots = CustomerProductSnapshotService.call(emails: emails, product_key: product_key, reference_date: today)
    customers_for(emails).filter_map do |c|
      snap = snapshots[c.email]
      next unless snap
      next if snap.last_order_date < today - ACTIVE_LOOKBACK_DAYS
      next if snap.overdue_days <= 0
      next if snap.overdue_days > RETURN_WINDOW_DAYS

      priority = (MEMBERSHIP_RANK.fetch(c.membership_level, 0) * 3) + (snap.overdue_days / 10.0) + (snap.order_count * 0.5)
      {
        customer: c, last_product: snap.last_product_name, last_date: snap.last_order_date,
        bottles: snap.bottles, overdue_days: snap.overdue_days, history_count: snap.order_count,
        history_amount: snap.total_amount, priority_score: priority.round(1)
      }
    end.sort_by { |r| [-MEMBERSHIP_RANK.fetch(r[:customer].membership_level, 0), -r[:history_count], -r[:history_amount].to_f] }
  end
end
