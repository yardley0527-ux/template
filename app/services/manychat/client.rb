# frozen_string_literal: true

require "net/http"

module Manychat
  # ManyChat Public API（https://api.manychat.com/swagger）。一把金鑰只對應一個帳號，
  # 金鑰放 ENV["MANYCHAT_API_KEYS"]，JSON 格式 {"IG帳號名稱": "金鑰", ...}。
  class Client
    class Error < StandardError; end

    BASE_URL = "https://api.manychat.com"

    def self.api_keys
      JSON.parse(ENV["MANYCHAT_API_KEYS"].presence || "{}")
          .transform_keys { |k| ShoplineCustomer.normalize_ig(k) }
    rescue JSON::ParserError
      {}
    end

    def self.for_account(account_key)
      key = api_keys[account_key]
      key && new(key)
    end

    def initialize(api_key)
      @api_key = api_key
    end

    def custom_fields
      get("/fb/page/getCustomFields")
    end

    def create_custom_field(caption:, type:, description: nil)
      post("/fb/page/createCustomField", { caption: caption, type: type, description: description.to_s })
    end

    # fields: { "欄位名稱" => 值 }，一次最多 20 個
    def set_custom_fields(subscriber_id, fields)
      post("/fb/subscriber/setCustomFields",
           { subscriber_id: subscriber_id,
             fields: fields.map { |name, value| { field_name: name, field_value: value } } })
    end

    private

    def get(path)
      request(Net::HTTP::Get.new(URI(BASE_URL + path)))
    end

    def post(path, body)
      req = Net::HTTP::Post.new(URI(BASE_URL + path))
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      request(req)
    end

    def request(req)
      req["Authorization"] = "Bearer #{@api_key}"
      uri = req.uri
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(req)
      end
      parsed = JSON.parse(response.body.presence || "{}")
      unless response.is_a?(Net::HTTPSuccess) && parsed["status"] == "success"
        detail = parsed.dig("details", "messages")&.map { |m| m["message"] }&.join("; ")
        raise Error, "#{response.code} #{parsed['message']} #{detail}".strip
      end

      parsed["data"]
    end
  end
end
