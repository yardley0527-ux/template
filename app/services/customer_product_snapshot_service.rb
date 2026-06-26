class CustomerProductSnapshotService
  def self.call(emails:, product_key:, reference_date:)
    emails = Array(emails).reject(&:blank?)
    return {} if emails.empty?

    raw = ProductNameResolver.orders_for(product_key)
      .where(email: emails)
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_by_email = {}
    raw.each do |email, product_name, order_date|
      last_by_email[email] ||= { product_name: product_name, order_date: order_date }
    end

    last_by_email.each_with_object({}) do |(email, last), result|
      bottles = BottleExtractor.call(last[:product_name], product_key)
      result[email] = CustomerProductSnapshot.new(
        email:             email,
        product_key:       product_key,
        last_product_name: last[:product_name],
        last_order_date:   last[:order_date].to_date,
        bottles:           bottles,
        reference_date:    reference_date
      )
    end
  end
end
