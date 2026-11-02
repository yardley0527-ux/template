# frozen_string_literal: true

require "net/http"

module IgInbox
  # Meta Graph API（Instagram API with Facebook Login）：用粉專的 Page access token 讀 IG 私訊對話、從官方帳號回訊息。
  # 帳號設定在 ENV["META_IG_ACCOUNTS"]，JSON 陣列，每個 IG 帳號一筆：
  #   [{"key": "chloechao0527", "page_id": "粉專 ID", "ig_user_id": "IG 專業帳號 ID", "token": "Page access token"}]
  # token 用 rake ig_inbox:page_tokens 從 Graph API Explorer 的使用者權杖換成不會過期的 Page token。
  class Client
    class Error < StandardError; end

    Account = Struct.new(:key, :page_id, :ig_user_id, :token, keyword_init: true)

    def self.version = ENV["META_GRAPH_VERSION"].presence || "v23.0"

    def self.accounts
      JSON.parse(ENV["META_IG_ACCOUNTS"].presence || "[]").map do |h|
        Account.new(key: h["key"].to_s.delete_prefix("@").downcase, page_id: h["page_id"].to_s,
                    ig_user_id: h["ig_user_id"].to_s, token: h["token"].to_s)
      end
    rescue JSON::ParserError
      []
    end

    def self.account(key) = accounts.find { |a| a.key == key }

    def initialize(account)
      @account = account
    end

    # 最近更新的對話（新到舊），每個對話附最近 limit 則訊息；遇到比 since 舊的對話就停
    def conversations(since:, messages_limit: 10)
      fields = "id,updated_time,participants,messages.limit(#{messages_limit}){id,message,from,created_time}"
      url = "#{base}/#{@account.page_id}/conversations?#{URI.encode_www_form(platform: 'instagram', fields: fields, limit: 25, access_token: @account.token)}"
      results = []
      while url
        body = get(url)
        Array(body["data"]).each do |c|
          return results if Time.zone.parse(c["updated_time"].to_s) < since

          results << c
        end
        url = body.dig("paging", "next")
      end
      results
    end

    # 回覆客人；human_agent: true 時加「真人客服」標記（客人最後一則訊息超過 24 小時、7 天內）
    def send_text(igsid, text, human_agent: false)
      payload = { recipient: { id: igsid }, message: { text: text } }
      payload.merge!(messaging_type: "MESSAGE_TAG", tag: "HUMAN_AGENT") if human_agent
      post("#{base}/#{@account.page_id}/messages", payload)
    end

    private

    def base = "https://graph.facebook.com/#{self.class.version}"

    def get(url)
      request(Net::HTTP::Get.new(URI(url)))
    end

    def post(url, payload)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["content-type"] = "application/json"
      req["authorization"] = "Bearer #{@account.token}"
      req.body = payload.to_json
      request(req)
    end

    def request(req)
      uri = req.uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 60
      response = http.request(req)
      body = JSON.parse(response.body.presence || "{}")
      unless response.code == "200"
        raise Error, "Meta API #{response.code}: #{body.dig('error', 'message') || response.body.to_s.truncate(200)}"
      end

      body
    end
  end
end
