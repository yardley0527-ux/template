# frozen_string_literal: true

class RefreshCustomerSeriesLoyaltiesJob < ApplicationJob
  queue_as :default

  def perform
    CustomerSeriesLoyaltyRefreshService.call
  end
end
