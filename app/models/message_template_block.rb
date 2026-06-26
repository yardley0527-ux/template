class MessageTemplateBlock < ApplicationRecord
  belongs_to :message_template
  has_many :message_template_images, -> { order(:position) }, dependent: :destroy

  validates :block_type, inclusion: { in: %w[text images] }
end
