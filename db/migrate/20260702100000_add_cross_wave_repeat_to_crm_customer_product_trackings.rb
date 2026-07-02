# frozen_string_literal: true

# VIP classification used to be "order_count >= 2" measured over each
# product's full order history with no time bound. Products sell in
# restock waves (stock in, sells out, gap until next restock) rather than
# continuously, so a plain purchase count doesn't distinguish a genuinely
# loyal repeat buyer from someone who happened to place two orders during
# the same restock. cross_wave_repeat instead marks customers who bought in
# both the most recent restock wave and the one before it — see
# WaveRepeatCalculator.
class AddCrossWaveRepeatToCrmCustomerProductTrackings < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_customer_product_trackings, :cross_wave_repeat, :boolean, default: false, null: false
  end
end
