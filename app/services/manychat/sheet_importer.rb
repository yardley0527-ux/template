# frozen_string_literal: true

require "csv"
require "open-uri"

module Manychat
  # ManyChat Flow 的 Google Sheets「Insert Row」動作，每次客人互動就寫一列。
  # 這裡下載整份表（試算表需開「知道連結的人可檢視」），寫進 manychat_subscribers。
  # 第一列是欄位標題：account, subscriber_id, ig_username, name, time（順序不拘）。
  # 同一人會有多列，取最後一列。
  class SheetImporter
    def self.call(sheet_id = ENV["MANYCHAT_SHEET_ID"])
      new(sheet_id).call
    end

    def initialize(sheet_id, csv: nil)
      @sheet_id = sheet_id
      @csv = csv
    end

    def call
      raise ArgumentError, "MANYCHAT_SHEET_ID 未設定" if @sheet_id.blank? && @csv.nil?

      latest = {}
      CSV.parse(@csv || download, headers: true).each do |row|
        h = row.to_h.transform_keys { |k| k.to_s.strip.downcase }
        account = ShoplineCustomer.normalize_ig(h["account"])
        subscriber_id = h["subscriber_id"].to_s.strip
        next if account.blank? || subscriber_id !~ /\A\d+\z/

        latest[[account, subscriber_id.to_i]] = h
      end

      result = { rows: latest.size, created: 0, updated: 0, invalid: 0 }
      latest.each do |(account, subscriber_id), h|
        record = ManychatSubscriber.find_or_initialize_by(account_key: account, subscriber_id: subscriber_id)
        record.assign_attributes(
          ig_username: h["ig_username"].presence || record.ig_username,
          name: h["name"].presence || record.name,
          last_interaction_at: parse_time(h["time"]) || record.last_interaction_at
        )
        next unless record.new_record? || record.changed? || record.shopline_customer_id.nil?

        was_new = record.new_record?
        if record.save
          result[was_new ? :created : :updated] += 1
        else
          result[:invalid] += 1
        end
      end
      result
    end

    private

    def download
      url = "https://docs.google.com/spreadsheets/d/#{@sheet_id}/export?format=csv"
      URI.parse(url).open(open_timeout: 15, read_timeout: 60).read.force_encoding("UTF-8")
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
