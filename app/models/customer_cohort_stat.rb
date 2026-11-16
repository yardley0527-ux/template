# frozen_string_literal: true

# 首購產品分析結果表，一個客人一列（見 CustomerCohortStatsRefreshService）
class CustomerCohortStat < ApplicationRecord
  def cross
    cross_families.to_a
  end
end
