# frozen_string_literal: true

class LineBotGroup < ApplicationRecord
  validates :group_id, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
end
