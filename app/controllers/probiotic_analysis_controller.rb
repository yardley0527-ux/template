class ProbioticAnalysisController < ApplicationController
  include ProductLivestreamAnalysis

  self.product_sql        = "product_name LIKE '%益生菌%'"
  self.product_label      = "益生菌"
  self.product_regex      = /益生菌(\d+)/
  PROBIOTIC_EVENT_DATES = [Date.new(2026, 2, 6), Date.new(2026, 3, 20)].freeze

  self.product_event_list = LivestreamAnalysisController::ALL_EVENTS
    .select { |e| PROBIOTIC_EVENT_DATES.include?(e[:date]) }.freeze

  def index
    @all_probiotic_events = product_event_list.select { |e| e[:date] <= Date.today }
    build_comprehensive_data(@all_probiotic_events)
    build_sku_data(@all_probiotic_events)
  end

  private

  def build_sku_data(all_events)
    return if all_events.empty?

    @sku_by_event = all_events.map do |ev|
      range = ev[:date].beginning_of_day..(ev[:date] + 3).end_of_day
      rows  = ShoplineOrder.where(product_sql).where(order_date: range)
                .where.not(email: [nil, ""])
                .pluck(:product_name, :email, :checkout_amount, :total_amount)

      grouped = rows.group_by { |pname, _e, _c, _t| pname }
      skus = grouped.map do |pname, entries|
        buyers  = entries.map { |_, e, _, _| e }.uniq.size
        revenue = entries.sum { |_, _, c, t| (c.to_f > 0 ? c : t).to_f }.to_i
        { product_name: pname, boxes: extract_bottles(pname),
          buyers: buyers, orders: entries.size, revenue: revenue }
      end.sort_by { |s| s[:boxes] }

      total_rev = skus.sum { |s| s[:revenue] }
      skus.each { |s| s[:rev_pct] = pct(s[:revenue], total_rev) }

      { event: ev, skus: skus,
        total_buyers: rows.map { |_, e, _, _| e }.uniq.size,
        total_orders: rows.size, total_revenue: total_rev }
    end

    all_sku_data   = @sku_by_event.flat_map { |e| e[:skus] }
    sku_names      = all_sku_data.map { |s| s[:product_name] }.uniq
                                 .sort_by { |n| extract_bottles(n) }
    grand_total    = all_sku_data.sum { |s| s[:revenue] }

    @sku_summary = sku_names.map do |name|
      entries = all_sku_data.select { |s| s[:product_name] == name }
      rev     = entries.sum { |s| s[:revenue] }
      { product_name: name,
        boxes:         extract_bottles(name),
        total_buyers:  entries.sum { |s| s[:buyers] },
        total_orders:  entries.sum { |s| s[:orders] },
        total_revenue: rev,
        rev_pct:       pct(rev, grand_total) }
    end
    @sku_grand_total = grand_total
  end

  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(product_regex)
    return m[1].to_i if m
    m = product_name.match(/[（(](\d+)[瓶盒]/)
    return m[1].to_i if m
    1
  end
end
