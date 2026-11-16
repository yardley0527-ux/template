# frozen_string_literal: true

# 首購產品分析結果表重算：計算全部在資料庫裡跑，web 程序只等結果
class RefreshCustomerCohortStatsJob < ApplicationJob
  queue_as :default

  def perform
    CustomerCohortStatsRefreshService.call
  end
end
