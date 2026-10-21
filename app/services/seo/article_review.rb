# frozen_string_literal: true

require "net/http"

module Seo
  # 昨日文章健檢：抓 shengtingbio.com 前一天（週一抓週五到週日）新發的文章，
  # 依苼莛改寫規則（AIO/GEO 格式）做能直接算出來的檢查；「開頭有沒有直接給答案」
  # 這種要判斷的交給 LineDigest 的 AI 寫一句建議（first_paragraph 給它看）。
  # 讀的是公開 REST API，不需要 WordPress 帳密。
  class ArticleReview
    API = "https://shengtingbio.com/wp-json/wp/v2/posts"
    MAX_TABLES = 2       # 改寫規則：一篇最多 2 個表格
    MIN_FAQ = 15         # 改寫規則：FAQ 15–20 題
    DESCRIPTION_MAX = 160

    def initialize(date: Date.current, fetcher: method(:get))
      @date = date
      @fetcher = fetcher
    end

    def call
      posts.map { |post| review(post) }
    end

    # 週一要看週五～週日（週末發的文章也要有人看）
    def window
      days = @date.monday? ? 3 : 1
      (@date - days)...@date
    end

    private

    def posts
      params = { after: "#{window.first}T00:00:00", before: "#{window.last}T00:00:00", per_page: 20,
                 status: "publish", _fields: "id,date,link,title,content" }
      JSON.parse(@fetcher.call("#{API}?#{params.to_query}"))
    end

    def review(post)
      html = post.dig("content", "rendered").to_s
      doc = Nokogiri::HTML.fragment(html)
      title = CGI.unescapeHTML(Nokogiri::HTML.fragment(post.dig("title", "rendered").to_s).text).strip
      h2s = doc.css("h2").map { |h| h.text.strip }
      images = doc.css("img")
      missing_alt = images.count { |img| img["alt"].to_s.strip.empty? }
      tables = doc.css("table").size
      faq = faq_count(doc, h2s)
      product_links = doc.css("a[href]").count { |a| a["href"].match?(%r{\Ahttps?://(www\.)?yardley\.tw/}) }
      description = meta_description(post["link"])

      flags = []
      # 「X 是什麼？完整解析」這種問句在前、副標在後的也算問句
      flags << "標題不是問句" unless title.match?(/[？?]/)
      flags << "表格 #{tables} 個（上限 #{MAX_TABLES}）" if tables > MAX_TABLES
      flags << (faq.zero? ? "沒有 FAQ" : "FAQ 只有 #{faq} 題（建議 #{MIN_FAQ}–20 題）") if faq < MIN_FAQ
      flags << "沒有連到 yardley 商品頁" if product_links.zero?
      flags << "缺 Meta Description" if description&.empty?
      flags << "Meta Description #{description.length} 字（上限 #{DESCRIPTION_MAX}）" if description && description.length > DESCRIPTION_MAX
      flags << "#{missing_alt} 張圖片缺 alt" if missing_alt.positive?

      { "id" => post["id"], "title" => title, "link" => post["link"], "date" => post["date"],
        "flags" => flags, "h2s" => h2s, "faq_count" => faq, "tables" => tables,
        "first_paragraph" => doc.css("p").map { |p| p.text.strip }.find(&:present?).to_s.truncate(250) }
    end

    # FAQ 標題常寫成「常見問題 FAQ（10 題完整解析）」「10 大常見問題（FAQ）」，有數字就用數字；
    # 沒寫的話數 FAQ 標題之後以問號結尾的小標／粗體
    def faq_count(doc, h2s)
      heading = h2s.find { |h| h.match?(/FAQ|常見問題|Q&A/i) }
      return 0 unless heading

      return Regexp.last_match(1).to_i if heading =~ /(\d+)\s*(題|大|個)/

      node = doc.css("h2").find { |h| h.text.strip == heading }
      questions = 0
      while (node = node&.next_element)
        break if node.name == "h2"

        questions += node.css("h3, h4, strong, summary").count { |q| q.text.strip.end_with?("？", "?") }
        questions += 1 if %w[h3 h4].include?(node.name) && node.text.strip.end_with?("？", "?")
      end
      questions
    end

    # nil＝抓不到頁面（不判斷）、""＝頁面沒有 description
    def meta_description(link)
      html = @fetcher.call(link)
      Nokogiri::HTML(html).at_css("meta[name='description']")&.[]("content").to_s.strip
    rescue StandardError
      nil
    end

    def get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = HealthCheck::USER_AGENT
      response = http.request(req)
      raise "HTTP #{response.code} #{url}" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s.dup.force_encoding("UTF-8")
    end
  end
end
