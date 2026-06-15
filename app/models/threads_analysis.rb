class ThreadsAnalysis < ApplicationRecord
  def self.latest_record
    order(fetched_on: :desc).first
  end
end
