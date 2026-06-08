# frozen_string_literal: true

class CustomerMergeLog < ApplicationRecord
  validates :orphan_customer_id, :official_customer_id, presence: true
end
