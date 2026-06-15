class ThreadsAnalysis < ApplicationRecord
  scope :latest_record, -> { order(fetched_on: :desc).first }
end
