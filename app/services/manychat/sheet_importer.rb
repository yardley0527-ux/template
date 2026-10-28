# frozen_string_literal: true

require "csv"
require "open-uri"

module Manychat
  # ManyChat Flow 的 Google Sheets「Insert Row」動作，每次客人互動就寫一列。
  # 這裡下載整份表（試算表需開「知道連結的人可檢視」），寫進 manychat_subscribers。
  # 第一列是欄位標題：account, subscriber_id, ig_username, name, time, source（順序不拘，source 可省略）。
  # 同一人會有多列：訂閱者資料取最後一列；每一列另外記成一次互動（manychat_interactions），
  # source 是 automation 在「來源」自訂欄位填的名字，用來看客人從哪篇貼文進來。
  #
  # Flow 的 Insert Row 不能填固定文字，所以每個 ManyChat 帳號寫各自的分頁，
  # ENV["MANYCHAT_SHEET_TABS"] = {"分頁 gid": "IG帳號"}，account 欄空白時用分頁對應的帳號。
  class SheetImporter
    def self.call(sheet_id = ENV["MANYCHAT_SHEET_ID"], tabs: tabs_from_env)
      new(sheet_id, tabs: tabs).call
    end

    def self.tabs_from_env
      JSON.parse(ENV["MANYCHAT_SHEET_TABS"].presence || "{}")
    rescue JSON::ParserError
      {}
    end

    # csv：測試用，{gid => CSV 字串}（沒有分頁設定時 key 用 nil）
    def initialize(sheet_id, tabs: {}, csv: nil)
      @sheet_id = sheet_id
      @tabs = tabs.presence || { nil => nil }
      @csv = csv
    end

    def call
      raise ArgumentError, "MANYCHAT_SHEET_ID 未設定" if @sheet_id.blank? && @csv.nil?

      latest = {}
      row_counts = Hash.new(0)
      events = []
      @tabs.each do |gid, tab_account|
        default_account = ShoplineCustomer.normalize_ig(tab_account)
        CSV.parse(@csv ? @csv[gid].to_s : download(gid), headers: true).each do |row|
          h = row.to_h.transform_keys { |k| k.to_s.strip.downcase }
          account = ShoplineCustomer.normalize_ig(h["account"]) || default_account
          subscriber_id = h["subscriber_id"].to_s.gsub(/[,\s]/, "")
          next if account.blank? || subscriber_id !~ /\A\d+\z/

          latest[[account, subscriber_id.to_i]] = h
          row_counts[[account, subscriber_id.to_i]] += 1
          at = parse_time(h["time"])
          events << [account, subscriber_id.to_i, at, h["source"].to_s.strip] if at
        end
      end

      result = { rows: latest.size, created: 0, updated: 0, invalid: 0, interactions: 0 }
      ids = {}
      latest.each do |(account, subscriber_id), h|
        record = ManychatSubscriber.find_or_initialize_by(account_key: account, subscriber_id: subscriber_id)
        record.assign_attributes(
          ig_username: h["ig_username"].presence || record.ig_username,
          name: h["name"].presence || record.name,
          last_interaction_at: parse_time(h["time"]) || record.last_interaction_at
        )
        # 多了新的列＝有新互動；Flow 不一定有填 time，交給 InteractionBackfill 用 API 補
        rows = row_counts[[account, subscriber_id]]
        record.assign_attributes(sheet_rows: rows, api_checked_at: nil) if rows != record.sheet_rows
        if record.new_record? || record.changed? || record.shopline_customer_id.nil?
          was_new = record.new_record?
          if record.save
            result[was_new ? :created : :updated] += 1
          else
            result[:invalid] += 1
          end
        end
        ids[[account, subscriber_id]] = record.id if record.persisted?
      end

      result[:interactions] = save_interactions(events, ids)
      result
    end

    private

    def download(gid)
      url = "https://docs.google.com/spreadsheets/d/#{@sheet_id}/export?format=csv"
      url += "&gid=#{gid}" if gid
      URI.parse(url).open(open_timeout: 15, read_timeout: 60).read.force_encoding("UTF-8")
    end

    def save_interactions(events, ids)
      now = Time.current
      rows = events.filter_map do |account, subscriber_id, at, source|
        id = ids[[account, subscriber_id]]
        id && { manychat_subscriber_id: id, interacted_at: at, source: source, created_at: now, updated_at: now }
      end.uniq { |r| r.values_at(:manychat_subscriber_id, :interacted_at, :source) }
      return 0 if rows.empty?

      before = ManychatInteraction.count
      rows.each_slice(1000) do |slice|
        ManychatInteraction.insert_all(slice, unique_by: :index_manychat_interactions_uniqueness)
      end
      ManychatInteraction.count - before
    end

    # 試算表偶爾把時間存成 Google Sheets 的日期序號（如 46319.3442 = 從 1899/12/30 起算的天數）
    SHEET_EPOCH = Date.new(1899, 12, 30)

    def parse_time(value)
      v = value.to_s.strip
      return nil if v.blank?
      if v.match?(/\A\d+(\.\d+)?\z/)
        days = v.to_f
        return (SHEET_EPOCH + days.floor).in_time_zone + ((days - days.floor) * 86_400).round
      end

      Time.zone.parse(v)
    rescue ArgumentError
      nil
    end
  end
end
