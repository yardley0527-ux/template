class CustomerProductSnapshotService
  def self.call(emails:, product_key:, reference_date:, before_date: nil)
    emails = Array(emails).reject(&:blank?)
    return {} if emails.empty?

    base_scope = ProductNameResolver.orders_for(product_key).where(email: emails)

    # Q1: Last product order per email (date-scoped when before_date is given)
    last_scope = before_date ? base_scope.where("order_date < ?", before_date) : base_scope
    raw = last_scope
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_by_email = {}
    raw.each do |email, product_name, order_date|
      last_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    return {} if last_by_email.empty?

    # Q2: Total order count per email (all orders, no date filter)
    counts = base_scope.group(:email).count

    # Q3: Deduplicated total spend per email (mirrors email_order_amounts in concern)
    amounts = order_amounts(base_scope)

    last_by_email.each_with_object({}) do |(email, last), result|
      bottles = BottleExtractor.call(last[:product_name], product_key)
      result[email] = CustomerProductSnapshot.new(
        email:             email,
        product_key:       product_key,
        last_product_name: last[:product_name],
        last_order_date:   last[:order_date].to_date,
        bottles:           bottles,
        reference_date:    reference_date,
        order_count:       counts[email]  || 0,
        total_amount:      amounts[email] || 0.0
      )
    end
  end

  private_class_method def self.order_amounts(scope)
    order_totals = scope
      .group(:email, :order_number)
      .pluck(
        :email,
        Arel.sql("MAX(NULLIF(total_amount, 0)) AS max_total"),
        Arel.sql("SUM(COALESCE(checkout_amount, 0)) AS sum_checkout")
      )

    order_totals.each_with_object(Hash.new(0.0)) do |(email, max_total, sum_checkout), acc|
      acc[email] += (max_total || sum_checkout).to_f
    end
  end
end
