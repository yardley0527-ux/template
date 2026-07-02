# frozen_string_literal: true

# Determines cross-wave repeat purchasers for a product.
#
# Products in this store are sold in restock "waves" — stock arrives, sells
# out over days/weeks, then there's a gap with zero orders until the next
# restock. A calendar-day recency window (e.g. "bought in the last 90 days")
# misclassifies customers during a stockout: everyone's days-since-last-order
# grows even though nothing changed about their loyalty.
#
# Instead, group order dates into waves (a new wave starts after a gap of
# more than WAVE_GAP_DAYS with no orders for that product), then flag
# customers who bought in both the current wave and the immediately
# preceding wave — i.e. they came back the next time stock was available.
class WaveRepeatCalculator
  WAVE_GAP_DAYS = 14

  def self.call(product_sql)
    new(product_sql).call
  end

  def initialize(product_sql)
    @product_sql = product_sql
  end

  # Returns { email => true/false } — true if the customer ordered in both
  # the most recent wave and the wave immediately before it.
  def call
    rows = ShoplineOrder.where(@product_sql).where.not(email: [nil, ""])
      .pluck(:email, :order_date)
      .map { |email, date| [email, date.to_date] }

    return {} if rows.empty?

    wave_by_date  = build_wave_index(rows.map(&:last).uniq.sort)
    current_wave  = wave_by_date.values.max
    previous_wave = current_wave - 1

    waves_by_email = Hash.new { |h, k| h[k] = [] }
    rows.each { |email, date| waves_by_email[email] << wave_by_date[date] }

    waves_by_email.transform_values do |waves|
      waves.include?(current_wave) && waves.include?(previous_wave)
    end
  end

  private

  # sorted_dates: unique order dates, ascending. Returns { date => wave_number }.
  def build_wave_index(sorted_dates)
    index = {}
    wave  = 0
    prev  = nil
    sorted_dates.each do |date|
      wave += 1 if prev.nil? || (date - prev) > WAVE_GAP_DAYS
      index[date] = wave
      prev = date
    end
    index
  end
end
