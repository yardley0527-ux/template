# path: app/models/import_run.rb
class ImportRun < ApplicationRecord
  KIND_LABELS = {
    "paid_orders_workbook" => "已付款訂單",
    "customers_report" => "顧客名單"
  }.freeze

  validates :kind, :file_name, :file_checksum, presence: true

  def add_error(message)
    self.error_messages = (error_messages + [message]).last(2000)
  end

  def kind_label
    KIND_LABELS.fetch(kind, kind)
  end
end
