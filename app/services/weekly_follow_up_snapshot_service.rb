class WeeklyFollowUpSnapshotService
  THRESHOLD = 10_000

  def self.call
    new.call
  end

  def call
    monday = Date.today.beginning_of_week(:monday)

    CustomerPurchaseSummary
      .where("first_amount >= ?", THRESHOLD)
      .where(purchase_count: 1)
      .update_all(follow_up_week: nil)

    CustomerPurchaseSummary
      .where("first_amount >= ?", THRESHOLD)
      .where(purchase_count: 1)
      .find_each do |customer|
        next if customer.first_date.nil?

        days_since = (Date.today - customer.first_date.to_date).to_i
        cycle = HighSpenderFirstPurchaseHelper::SERIES_CYCLE_DAYS.fetch(customer.first_series.to_s, 90)

        if days_since >= (cycle * 0.7).to_i && days_since < cycle
          customer.update_column(:follow_up_week, monday)
        end
      end

    monday
  end
end
