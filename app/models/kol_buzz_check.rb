class KolBuzzCheck < ApplicationRecord
  SENTIMENTS = %w[positive neutral negative mixed unknown].freeze

  belongs_to :kol_candidate

  validates :summary, presence: true
  validates :sentiment, inclusion: { in: SENTIMENTS }

  before_validation { self.checked_at ||= Time.current }
end
