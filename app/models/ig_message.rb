class IgMessage < ApplicationRecord
  belongs_to :ig_conversation
  belongs_to :sent_by_user, class_name: "User", optional: true
end
