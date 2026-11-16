# frozen_string_literal: true

module OrderBrief
  # 一段期間「每天」的營收、單數、新舊客合計，口徑同 Report（逐天各算一份 Report 的結果）：
  # - 只算已付款；整單金額取 total_amount 最大值，整張單都空白就用各行 checkout_amount 加總
  # - 新客＝這天以前（含同 IG 的分身 email）沒有已付款訂單
  # 跟 Report 不同的是不載入每個人的完整購買歷史，只撈「每個 email 第一次付款是哪天」，
  # 銷售日報「當月累計」要算到月底 30 天時才不會把正式站記憶體吃光（2026-11-16 web 被 OOM 重開）。
  class DailyTotals
    Day = Struct.new(:amount, :orders, :new_amount, :new_orders, keyword_init: true) do
      def old_amount = amount - new_amount
      def empty? = orders.zero?
    end

    EMPTY = Day.new(amount: 0.0, orders: 0, new_amount: 0.0, new_orders: 0).freeze

    def initialize(days)
      @days = days.first.to_date..days.last.to_date
    end

    def [](date)
      by_day.fetch(date.to_date, EMPTY)
    end

    private

    def by_day
      @by_day ||= build
    end

    def paid_orders
      ShoplineOrder.where(payment_status: "已付款")
    end

    def build
      orders = paid_orders.where("order_date::date BETWEEN ? AND ?", @days.first, @days.last).where.not(email: nil)
                          .group(Arel.sql("lower(trim(email))"), :order_number)
                          .pluck(Arel.sql("lower(trim(email))"), Arel.sql("MIN(order_date::date)"),
                                 Arel.sql("MAX(total_amount)"), Arel.sql("SUM(COALESCE(checkout_amount, 0))"))
      return {} if orders.empty?

      emails = orders.map(&:first).uniq
      load_customers(emails)
      first_paid = first_paid_dates(emails.flat_map { |e| siblings(e) }.uniq)

      # 一人一天可能多張單；新舊客以這天為準，同一天的單都算同一邊
      orders.group_by { |_, date, _, _| date.to_date }.transform_values do |day_orders|
        day = Day.new(amount: 0.0, orders: 0, new_amount: 0.0, new_orders: 0)
        day_orders.each do |email, date, total, checkout|
          amount = total.to_f.positive? ? total.to_f : checkout.to_f
          day.amount += amount
          day.orders += 1
          next unless new_on?(email, date.to_date, first_paid)

          day.new_amount += amount
          day.new_orders += 1
        end
        day
      end
    end

    def new_on?(email, date, first_paid)
      siblings(email).none? { |e| (d = first_paid[e]) && d < date }
    end

    def first_paid_dates(emails)
      emails.each_slice(2000).each_with_object({}) do |slice, h|
        paid_orders.where("lower(trim(email)) IN (?)", slice).group(Arel.sql("lower(trim(email))"))
                   .minimum(Arel.sql("order_date::date"))
                   .each { |em, d| h[em] = d.to_date }
      end
    end

    # 同 Report#load_customers：買家＋同 IG 的分身 email
    def load_customers(emails)
      @ig_of = {}
      @by_ig = Hash.new { |h, k| h[k] = [] }
      junk = Report::IG_JUNK
      igs = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails).pluck(Arel.sql("lower(trim(instagram_account))"))
                            .reject { |ig| ig.nil? || junk.include?(ig) }.uniq
      scope = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails)
      scope = scope.or(ShoplineCustomer.where("lower(trim(instagram_account)) IN (?)", igs)) if igs.any?
      scope.pluck(Arel.sql("lower(trim(email))"), Arel.sql("lower(trim(instagram_account))")).each do |em, ig|
        ig = nil if ig.nil? || junk.include?(ig)
        @ig_of[em] = ig
        @by_ig[ig] << em if ig
      end
    end

    def siblings(email)
      ig = @ig_of[email]
      ig ? ([email] + @by_ig[ig]).uniq : [email]
    end
  end
end
