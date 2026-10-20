# frozen_string_literal: true

require "net/http"
require "openssl"
require "base64"

module Seo
  # 用服務帳戶 seo-monitor@shengting-magazine-ver2 打 Google API（唯讀 scope）。
  # 金鑰來源：正式站 ENV["SEO_GOOGLE_SA_JSON"]（整份 JSON 內容），本機可用
  # ENV["SEO_GOOGLE_SA_PATH"] 或預設的 ~/.config/yardley/seo-monitor.json。
  # 刻意不引入 google-api gem：只需要 JWT 換 token + 兩個 POST，Net::HTTP 就夠。
  class GoogleApiClient
    class Error < StandardError; end

    SCOPES = %w[
      https://www.googleapis.com/auth/webmasters.readonly
      https://www.googleapis.com/auth/analytics.readonly
    ].freeze
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    DEFAULT_KEY_PATH = File.expand_path("~/.config/yardley/seo-monitor.json")

    def self.configured?
      ENV["SEO_GOOGLE_SA_JSON"].present? || File.exist?(key_path)
    end

    def self.key_path
      ENV["SEO_GOOGLE_SA_PATH"].presence || DEFAULT_KEY_PATH
    end

    def post_json(url, body)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{access_token}"
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      response = http_for(uri).request(req)
      parsed = JSON.parse(response.body.presence || "{}")
      raise Error, "#{response.code} #{parsed.dig('error', 'message')}" unless response.is_a?(Net::HTTPSuccess)

      parsed
    end

    private

    def access_token
      return @access_token if @access_token && @expires_at > Time.current + 60

      key = credentials
      now = Time.current.to_i
      claims = { iss: key["client_email"], scope: SCOPES.join(" "), aud: TOKEN_URL, iat: now, exp: now + 3600 }
      input = "#{b64({ alg: 'RS256', typ: 'JWT' }.to_json)}.#{b64(claims.to_json)}"
      signature = OpenSSL::PKey::RSA.new(key["private_key"]).sign("SHA256", input)

      response = Net::HTTP.post_form(URI(TOKEN_URL),
                                     grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                     assertion: "#{input}.#{b64(signature)}")
      parsed = JSON.parse(response.body)
      raise Error, "token: #{parsed['error_description'] || parsed['error']}" unless parsed["access_token"]

      @expires_at = Time.current + parsed["expires_in"].to_i
      @access_token = parsed["access_token"]
    end

    def credentials
      raw = ENV["SEO_GOOGLE_SA_JSON"].presence || File.read(self.class.key_path)
      JSON.parse(raw)
    rescue Errno::ENOENT
      raise Error, "找不到服務帳戶金鑰（SEO_GOOGLE_SA_JSON 未設定）"
    end

    def http_for(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 60
      end
    end

    def b64(str)
      Base64.urlsafe_encode64(str, padding: false)
    end
  end
end
