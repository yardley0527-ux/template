class HighSpenderFollowUp < ApplicationRecord
  validates :identity_key, presence: true
  validates :note, presence: true

  scope :for_keys, ->(keys) { where(identity_key: keys).order(followed_up_at: :desc) }
end
