# path: app/models/tag_extraction_recipient.rb
# frozen_string_literal: true

class TagExtractionRecipient < ApplicationRecord
  belongs_to :tag_extraction_run

  validates :category, :email, presence: true
end
