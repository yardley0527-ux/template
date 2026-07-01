class CustomerProductSnapshot
  DAYS_PER_BOTTLE = 30

  attr_reader :email, :product_key, :last_product_name, :last_order_date, :bottles,
              :reference_date, :order_count, :total_amount

  def initialize(email:, product_key:, last_product_name:, last_order_date:, bottles:,
                 reference_date:, order_count: 0, total_amount: 0.0)
    @email             = email
    @product_key       = product_key
    @last_product_name = last_product_name
    @last_order_date   = last_order_date
    @bottles           = bottles
    @reference_date    = reference_date
    @order_count       = order_count
    @total_amount      = total_amount
  end

  def expected_return_date
    @last_order_date + (bottles * DAYS_PER_BOTTLE)
  end

  # Positive = supply remaining. Negative = overdue.
  def days_until_return
    (expected_return_date - @reference_date).to_i
  end

  # Days of supply remaining; 0 if already overdue.
  def days_left
    [days_until_return, 0].max
  end

  # Days past the expected return date; 0 if still active.
  def overdue_days
    [-days_until_return, 0].max
  end

  def status
    if    days_until_return > 30  then :active
    elsif days_until_return >= 0  then :due_soon
    elsif days_until_return >= -30 then :overdue
    else                               :lost
    end
  end
end
