# frozen_string_literal: true

require "net/http"
require "openssl"
require "base64"

module LineBot
  # 「苼莛小幫手」LINE 官方帳號（內部用，不是 8 千多好友的品牌帳號）的 Messaging API。
  # 金鑰：LINE_REPORT_CHANNEL_ACCESS_TOKEN（推播）、LINE_REPORT_CHANNEL_SECRET（驗 webhook 簽章）。
  class Client
    class Error < StandardError; end

    API_BASE = "https://api.line.me/v2/bot"
    MAX_TEXT = 5000 # LINE 單則文字訊息上限

    def self.configured?
      ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"].present?
    end

    MAX_MESSAGES = 5 # push 一次最多 5 則

    # 段落依序塞進最多 5 則訊息，每則不超過上限；單一段落太長就按行切開
    def self.pack(sections, overflow_note: "（內容太長，後面省略）")
      chunks = sections.flat_map { |section| split_long(section) }
      out = chunks.each_with_object([]) do |chunk, acc|
        if acc.any? && acc.last.size + chunk.size + 2 <= MAX_TEXT
          acc[-1] = "#{acc.last}\n\n#{chunk}"
        else
          acc << chunk
        end
      end
      out.size <= MAX_MESSAGES ? out : out.first(MAX_MESSAGES - 1) + [overflow_note]
    end

    def self.split_long(section)
      return [section] if section.size <= MAX_TEXT

      section.lines.each_with_object([+""]) do |line, acc|
        acc << +"" if acc.last.size + line.size > MAX_TEXT
        acc.last << line
      end.map(&:chomp)
    end
    private_class_method :split_long

    # LINE 文字訊息超過約 20 行會被折起來（要按「See more」），切成每則都能直接看完的長度。
    # 手機一行約 22 個中文字，長句會折行，所以用「折行後的行數」估。先按空行分段，段落太長再按行切。
    PHONE_LINE_CHARS = 22
    READABLE_LINES = 18

    def self.split_readable(text)
      paragraphs = text.to_s.split(/\n{2,}/).flat_map { |para| split_paragraph(para) }
      paragraphs.each_with_object([]) do |para, out|
        if out.any? && visual_lines("#{out.last}\n\n#{para}") <= READABLE_LINES
          out[-1] = "#{out.last}\n\n#{para}"
        else
          out << para
        end
      end
    end

    def self.visual_lines(text)
      text.split("\n", -1).sum { |line| [(line.size.to_f / PHONE_LINE_CHARS).ceil, 1].max }
    end

    def self.split_paragraph(para)
      return [para] if visual_lines(para) <= READABLE_LINES

      para.split("\n").each_with_object([+""]) do |line, acc|
        acc << +"" if acc.last.present? && visual_lines("#{acc.last}\n#{line}") > READABLE_LINES
        acc.last << (acc.last.empty? ? line : "\n#{line}")
      end
    end
    private_class_method :split_paragraph

    def self.valid_signature?(body, signature)
      secret = ENV["LINE_REPORT_CHANNEL_SECRET"].to_s
      return false if secret.empty? || signature.blank?

      expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body))
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def push_text(to, text)
      push_texts(to, [text])
    end

    # 一次推多則（LINE 上限 5 則），群組裡會連續出現
    def push_texts(to, texts)
      push_messages(to, texts.map { |t| { type: "text", text: t.to_s.truncate(MAX_TEXT) } })
    end

    # 任意訊息物件（例如 Flex 卡片）
    def push_messages(to, messages)
      post("/message/push", { to: to, messages: messages.first(MAX_MESSAGES) })
    end

    def group_name(group_id)
      get("/group/#{group_id}/summary")["groupName"]
    rescue Error
      nil
    end

    def user_name(user_id)
      get("/profile/#{user_id}")["displayName"]
    rescue Error
      nil
    end

    private

    def post(path, body)
      request(Net::HTTP::Post.new(URI("#{API_BASE}#{path}")).tap { |r| r.body = body.to_json })
    end

    def get(path)
      request(Net::HTTP::Get.new(URI("#{API_BASE}#{path}")))
    end

    def request(req)
      token = ENV["LINE_REPORT_CHANNEL_ACCESS_TOKEN"].to_s
      raise Error, "LINE_REPORT_CHANNEL_ACCESS_TOKEN 未設定" if token.empty?

      req["Authorization"] = "Bearer #{token}"
      req["Content-Type"] = "application/json"
      http = Net::HTTP.new(req.uri.host, 443)
      http.use_ssl = true
      http.read_timeout = 30
      response = http.request(req)
      parsed = JSON.parse(response.body.presence || "{}")
      raise Error, "LINE #{response.code}: #{parsed['message']}" unless response.is_a?(Net::HTTPSuccess)

      parsed
    end
  end
end
