# path: app/models/import_run.rb
class ImportRun < ApplicationRecord
  validates :kind, :file_name, :file_checksum, presence: true

  def add_error(message)
    self.error_messages = (error_messages + [message]).last(2000)
  end
end
