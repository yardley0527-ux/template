# frozen_string_literal: true

require "csv"

module Manychat
  # ManyChat 的 Default Reply（客人的話沒對到任何關鍵字／自動回覆時）用 Insert Row 寫進試算表的「未回覆問題」分頁，
  # 這裡匯入成 ig_questions。欄位標題：subscriber_id, ig_username, name, time, question（順序不拘）。
  # 跟訂閱者分頁一樣每個 IG 帳號一個分頁：ENV["MANYCHAT_QUESTION_TABS"] = {"分頁 gid": "IG帳號"}。
  # 試算表只會往下加列，用「分頁＋第幾列」去重；time 空白時用第一次匯入的時間。
  class QuestionImporter
    def self.call(sheet_id = ENV["MANYCHAT_SHEET_ID"], tabs: tabs_from_env)
      new(sheet_id, tabs: tabs).call
    end

    def self.tabs_from_env
      JSON.parse(ENV["MANYCHAT_QUESTION_TABS"].presence || "{}")
    rescue JSON::ParserError
      {}
    end

    # csv：測試用，{gid => CSV 字串}
    def initialize(sheet_id, tabs: {}, csv: nil)
      @sheet_id = sheet_id
      @tabs = tabs
      @csv = csv
    end

    def call
      return { rows: 0, created: 0 } if @tabs.blank?
      raise ArgumentError, "MANYCHAT_SHEET_ID 未設定" if @sheet_id.blank? && @csv.nil?

      now = Time.current
      rows = @tabs.flat_map do |gid, tab_account|
        account = ShoplineCustomer.normalize_ig(tab_account)
        next [] if account.blank?

        CSV.parse(@csv ? @csv[gid].to_s : SheetImporter.download(@sheet_id, gid), headers: true).each_with_index.filter_map do |row, i|
          h = row.to_h.transform_keys { |k| k.to_s.strip.downcase }
          question = h["question"].to_s.strip
          next if question.blank?

          subscriber_id = h["subscriber_id"].to_s.gsub(/[,\s]/, "")
          { account_key: account, sheet_gid: gid.to_s, sheet_row: i + 2, # 第 1 列是標題
            subscriber_id: subscriber_id.match?(/\A\d+\z/) ? subscriber_id.to_i : nil,
            ig_username: h["ig_username"].presence, name: h["name"].presence, question: question,
            asked_at: SheetImporter.parse_time(h["time"]) || now, created_at: now, updated_at: now }
        end
      end
      return { rows: 0, created: 0 } if rows.empty?

      before = IgQuestion.count
      rows.each_slice(1000) do |slice|
        IgQuestion.insert_all(slice, unique_by: :index_ig_questions_uniqueness)
      end
      { rows: rows.size, created: IgQuestion.count - before }
    end
  end
end
