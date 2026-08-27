class AkimiaKocMessageTemplate < ApplicationRecord
  def self.current
    first_or_create!
  end
end
