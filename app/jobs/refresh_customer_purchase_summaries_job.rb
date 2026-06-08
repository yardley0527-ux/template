# frozen_string_literal: true

class RefreshCustomerPurchaseSummariesJob < ApplicationJob
  queue_as :default

  def perform
    CustomerPurchaseSummaryRefreshService.call
  end
end
