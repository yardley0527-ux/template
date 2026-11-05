# frozen_string_literal: true

module ReportCenter
  # 報告中心共用的訂單資料，口徑同訂單簡報（只算已付款、卡別用目前的、看 2024/1 起全部歷史＋IG 分身），另外：
  # - 尾碼 A 的拆單併回主單（A 單沒有 total_amount，金額已含在主單）
  # - 重複匯入、「X N」＋「X N送M」成對的行只算一次
  # - 新客＝「區間開始前」沒有已付款訂單，所以區間內第一次買、之後又買的人整段都算新客；只選一天時等於訂單簡報
  # - 下單時間來自訂單號碼前 14 碼（UTC，+8 小時是台灣時間）；order_date 欄位只有日期
  class Orders
    Line = Struct.new(:name, :quantity, :unit_price, keyword_init: true) do
      def preorder? = name.start_with?("預購-")
      def parsed = OrderBrief::Report.parse(name)
      def series = parsed[0]
      def size = parsed[1]
      def gift = parsed[2]
      def bottles = size * quantity
      def gift_bottles = gift * quantity
      def list_amount = unit_price * quantity
    end

    Order = Struct.new(:number, :date, :email, :lines, :amount, :payment, :city, :new_customer, keyword_init: true) do
      alias_method :new_customer?, :new_customer

      def list_amount = lines.sum(&:list_amount)

      # 訂單層級的折扣按比例攤回各行；購物金折抵後實付很小時，攤到的也會很小
      def share = list_amount.positive? ? [amount / list_amount, 1.0].min : 0.0

      def hour
        m = number.match(/\A#(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/)
        return unless m

        (Time.utc(*m.captures.map(&:to_i)) + 8.hours).hour
      rescue ArgumentError
        nil
      end
    end

    # 把訂單 scope 組成 Order：已付款行、A 單併主單、同行去重、整單金額
    def self.assemble(scope)
      seen = Set.new
      orders = {}
      checkout = Hash.new(0.0)
      scope.pluck(:order_number, Arel.sql("order_date::date"), Arel.sql("lower(trim(email))"), :product_name, :quantity, :total_amount,
                  :checkout_amount, :payment_method, :city)
           .sort_by(&:first) # 主單排在 A 單前面，付款方式、日期都以主單為準
           .each do |number, date, email, name, quantity, total, price, payment, city|
        base = number.to_s.delete_suffix("A")
        order = (orders[base] ||= Order.new(number: base, date: date.to_date, email: email, lines: [], amount: 0.0,
                                            payment: payment, city: city.presence))
        order.amount = [order.amount, total.to_f].max
        order.city ||= city.presence
        name = name.to_s.strip
        next unless seen.add?([number, name.sub(/送\d+\z/, ""), quantity, price])

        line = Line.new(name: name, quantity: (quantity || 1).to_i, unit_price: price.to_f)
        order.lines << line
        checkout[base] += line.list_amount
      end
      orders.each { |base, order| order.amount = checkout[base] unless order.amount.positive? }
      orders.values
    end

    def self.paid = ShoplineOrder.where(payment_status: "已付款")

    attr_reader :range, :product

    # product：只看含這個關鍵字商品的訂單（金額仍是整單）
    def initialize(range, product: nil)
      @range = range
      @product = product.to_s.strip.presence
    end

    def all
      @all ||= begin
        orders = self.class.assemble(self.class.paid.where("order_date::date BETWEEN ? AND ?", range.first, range.last)
                                         .where.not(email: [nil, ""]))
        orders = orders.select { |o| o.lines.any? { |l| match?(l.name) } } if product
        mark_new(orders)
      end
    end

    def empty? = all.empty?

    def identity
      @identity ||= Identity.new(all.map(&:email))
    end

    def new_orders = all.select(&:new_customer?)
    def old_orders = all.reject(&:new_customer?)

    def people(orders) = orders.map { |o| identity.person(o.email) }.uniq.size

    def match?(name) = name.downcase.include?(product.downcase)

    private

    def mark_new(orders)
      ident = (@identity = Identity.new(orders.map(&:email)))
      all_emails = orders.flat_map { |o| ident.siblings(o.email) }.uniq
      return orders if all_emails.empty?

      before = self.class.paid.where("lower(trim(email)) IN (?)", all_emails).where("order_date::date < ?", range.first)
                   .distinct.pluck(Arel.sql("lower(trim(email))")).to_set
      orders.each { |o| o.new_customer = ident.siblings(o.email).none? { |e| before.include?(e) } }
    end
  end
end
