class KolMetricSnapshot < ApplicationRecord
  PLATFORMS = %w[instagram tiktok youtube].freeze
  SOURCES = %w[manual apify].freeze

  belongs_to :kol_candidate

  validates :platform, inclusion: { in: PLATFORMS }
  validates :source, inclusion: { in: SOURCES }

  before_validation { self.fetched_at ||= Time.current }
end
