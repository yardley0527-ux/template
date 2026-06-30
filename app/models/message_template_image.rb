class MessageTemplateImage < ApplicationRecord
  belongs_to :message_template_block

  validates :cloudinary_public_id, :url, presence: true
end
