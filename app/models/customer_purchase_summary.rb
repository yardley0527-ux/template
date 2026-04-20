# app/models/customer_purchase_summary.rb
# frozen_string_literal: true

class CustomerPurchaseSummary < ApplicationRecord
  belongs_to :shopline_customer, primary_key: :email, foreign_key: :email, optional: true

  scope :silent, -> { where(silent_only: true) }
  scope :by_series, ->(series) { where(first_series: series) if series.present? }
end