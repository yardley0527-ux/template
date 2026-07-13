class SyncDepartmentSheetsJob < ApplicationJob
  queue_as :default

  def perform
    DepartmentSheetSync.call
  end
end
