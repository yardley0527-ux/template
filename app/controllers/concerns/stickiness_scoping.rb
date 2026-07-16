# frozen_string_literal: true

# 黏著度分析（名單、成效）共用的查詢邏輯：
# 名單來源是所有標了客人類型的客人，回購定義為「追蹤之後再次購買追蹤前買過的系列」
module StickinessScoping
  extend ActiveSupport::Concern

  LEVELS = HighValueOrderScoping::LEVELS

  Row = Struct.new(
    :profile, :customer, :customer_type, :membership_level,
    :last_purchase_date, :purchased_series, :repurchases,
    keyword_init: true
  ) do
    def tracked?
      profile.stickiness_note.present?
    end
  end

  private

  # 撈出所有標了客人類型的客人，帶購買歷史與回購結果
  def build_rows
    profiles = CustomerProfile.where(customer_type: CustomerProfile::CUSTOMER_TYPE_OPTIONS)
                              .includes(:shopline_customer)
                              .to_a
                              .select(&:shopline_customer)

    emails  = profiles.map { |p| p.shopline_customer.email }.compact.uniq
    history = emails.empty? ? [] : ShoplineOrder.where(email: emails)
                                                .where("payment_status = '已付款'")
                                                .pluck(:email, :product_name, :order_date, :order_number, :total_amount, :checkout_amount)

    order_totals    = Hash.new { |h, k| h[k] = { max_total: nil, sum_checkout: 0 } }
    series_by_email = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
    last_dates      = {}
    history.each do |email, name, date, order_number, total_amount, checkout_amount|
      t = order_totals[order_number]
      t[:max_total] = [t[:max_total], total_amount].compact.reject(&:zero?).max
      t[:sum_checkout] += checkout_amount.to_f
      series_by_email[email][product_series(name)] << { date: date, order_number: order_number, product_name: name }
      last_dates[email] = date if last_dates[email].nil? || date > last_dates[email]
    end
    series_by_email.each_value { |by_series| by_series.each_value { |list| list.sort_by! { |p| p[:date] } } }

    profiles.map do |profile|
      customer = profile.shopline_customer
      email    = customer.email
      Row.new(
        profile:            profile,
        customer:           customer,
        customer_type:      profile.customer_type,
        membership_level:   customer.membership_level.presence || "一般會員",
        last_purchase_date: last_dates[email],
        purchased_series:   series_by_email[email].keys,
        repurchases:        build_repurchases_for(profile, series_by_email[email], order_totals),
      )
    end
  end

  # 追蹤之後，客人是否再次購買「追蹤前買過的系列」；每個系列取追蹤後最早一筆
  def build_repurchases_for(profile, by_series, order_totals)
    tracked_at = profile.stickiness_followed_up_at
    return [] if tracked_at.blank?

    by_series.filter_map do |series, purchases|
      next unless purchases.any? { |p| p[:date] < tracked_at }

      rep = purchases.find { |p| p[:date] > tracked_at }
      next unless rep

      t = order_totals[rep[:order_number]]
      {
        series:       series,
        product_name: rep[:product_name],
        date:         rep[:date],
        order_number: rep[:order_number],
        amount:       (t[:max_total] || t[:sum_checkout]).to_i,
        days_between: (rep[:date].to_date - tracked_at.to_date).to_i,
      }
    end
  end

  # 追蹤成效圖表用：依卡別彙總名單人數、回購人數、回購業績。
  # 有給日期區間時以「回購日」為口徑（區間內發生的回購才算），分母維持整份追蹤名單
  def build_level_stats(rows, from: nil, to: nil)
    rows.group_by(&:membership_level)
        .sort_by { |level, _| LEVELS.index(level) || LEVELS.size }
        .map do |level, members|
          reps_by_member = members.map { |r| repurchases_within(r, from, to) }
          {
            level:            level,
            list_count:       members.size,
            repurchase_count: reps_by_member.count(&:any?),
            revenue:          reps_by_member.sum { |reps| reps.sum { |rep| rep[:amount] } },
          }
        end
  end

  def repurchases_within(row, from, to)
    return row.repurchases if from.blank?

    row.repurchases.select do |rep|
      rep[:date] >= from.beginning_of_day && rep[:date] <= to.end_of_day
    end
  end

  # 依客人類型分組，組內照卡別排序
  def group_by_customer_type(rows)
    CustomerProfile::CUSTOMER_TYPE_OPTIONS.map do |type|
      typed = rows.select { |r| r.customer_type == type }
                  .sort_by { |r| [LEVELS.index(r.membership_level) || LEVELS.size, r.last_purchase_date ? -r.last_purchase_date.to_i : 0] }
      [type, typed]
    end
  end

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def product_series(name)
    name.to_s.match(/\A([^\d]+)/)&.captures&.first&.strip.presence || name.to_s
  end
end
