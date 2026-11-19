# frozen_string_literal: true

require "cgi"

module Seo
  # 每週五的全站健檢：把官網 sitemap（中文版）裡每一頁都讀一次，檢查標題、描述、H1、
  # canonical、結構化資料、noindex、隱藏頁、站內壞連結，結果存 seo_site_audits 跟上週比。
  # 每日 HealthCheck 只抽 4 頁，這裡是整站。不用 AI。
  #
  # 約 520 頁 × 每頁間隔 2 秒，跑一次約 30 分鐘（Shopline 太密集會回「site is now busy」）。
  class SiteAudit < HealthCheck
    # 顯示順序＝嚴重程度。level：critical 要馬上處理／warning 該修／info 參考
    TYPES = {
      "page_error" => { label: "頁面打不開", level: "critical" },
      "noindex" => { label: "被設成不讓 Google 收錄（noindex）", level: "critical" },
      "broken_link" => { label: "站內連結點了是壞的", level: "critical" },
      "hidden_in_sitemap" => { label: "隱藏／預覽頁出現在 sitemap", level: "warning" },
      "no_seo_description" => { label: "沒填 SEO 描述（系統自動塞頁面內文）", level: "warning" },
      "missing_description" => { label: "沒有描述", level: "warning" },
      "duplicate_title" => { label: "標題跟其他頁重複", level: "warning" },
      "missing_h1" => { label: "沒有 H1 標題", level: "warning" },
      "missing_canonical" => { label: "缺 canonical 標籤", level: "warning" },
      "missing_product_schema" => { label: "產品頁缺 Product 結構化資料", level: "warning" },
      "missing_article_schema" => { label: "文章缺 BlogPosting 結構化資料", level: "warning" },
      "multilang_duplicate" => { label: "英文版 /en/ 跟中文內容重複", level: "warning" },
      "long_title" => { label: "標題超過 40 字（搜尋結果會被截斷）", level: "info" },
      "multiple_h1" => { label: "一頁有多個 H1", level: "info" }
    }.freeze

    SITE = "yardley"
    LOCALE_SITEMAP = "sitemap.xml?locale=zh-hant"
    TITLE_MAX = 40
    MAX_LINK_CHECKS = 80
    # 會員、購物車、搜尋這類頁面本來就不在 sitemap，不檢查
    SKIP_LINK = %r{\A/(?:users|cart|checkout|orders|account|search|api|sl|fast-checkout|apps|password|unsubscribe)(?:/|\z)}

    def initialize(max_pages: nil, **kwargs)
      super(**kwargs)
      @max_pages = max_pages
    end

    # 回傳存好的 SeoSiteAudit（健檢 issues＋搜尋數據 insights）
    def run!(insights: nil)
      result = audit
      insights = (insights || WeeklyInsights.new.call).dup
      insights["titles"] = referenced_titles(insights, result[:titles])
      SeoSiteAudit.find_or_initialize_by(site: SITE, audited_on: @date).tap do |record|
        record.update!(pages_checked: result[:checked], pages_skipped: result[:skipped], issues: result[:issues],
                       insights: insights)
      end
    end

    # 搜尋數據裡出現的頁面 → 爬到的頁面標題（LINE 用標題比網址好認）
    def referenced_titles(insights, titles)
      urls = %w[low_ctr striking].flat_map { |k| insights[k].to_a.map { |r| r["page"] } } +
             insights["drops"].to_a.map { |r| r["key"] }
      urls.compact.uniq.filter_map do |url|
        key = normalize(path_of(url))
        [key, titles[key]] if titles[key].present?
      end.to_h
    end

    def audit
      base = Sites::ALL.fetch(SITE)[:base_url]
      urls = sitemap_urls(base)
      urls = urls.first(@max_pages) if @max_pages
      issues = []
      pages = []
      skipped = 0

      urls.each do |url|
        response = fetch(escape(url))
        if response.nil?
          skipped += 1
          next
        end
        page = inspect_page(url, response)
        pages << page if page
        issues.concat(page ? page_issues(page) : [issue("page_error", url, nil, response.code.zero? ? response.body : "HTTP #{response.code}")])
      end

      issues.concat(duplicate_title_issues(pages))
      issues.concat(broken_link_issues(pages, urls))
      issues.concat(multilang_issues(base))
      titles = pages.to_h { |p| [normalize(path_of(p[:url])), p[:title]] }
      { checked: urls.size - skipped, skipped: skipped, issues: issues, titles: titles }
    end

    def sitemap_urls(base)
      response = fetch("#{base}/#{LOCALE_SITEMAP}")
      raise "讀不到 sitemap（#{response ? "HTTP #{response.code}" : '網站忙碌'}）" unless response&.code == 200 && response.body.include?("<loc>")

      xml_locs(response.body).uniq
    end

    # 回傳頁面摘要，或 nil（非 200）
    def inspect_page(url, response)
      return nil unless response.code == 200

      doc = Nokogiri::HTML(response.body)
      robots = doc.css("meta[name='robots'], meta[name='googlebot']").map { |m| m["content"].to_s.downcase }
      {
        url: url,
        title: doc.at_css("title")&.text.to_s.strip,
        descriptions: doc.css("meta[name='description']").map { |m| m["content"].to_s.strip },
        h1: doc.css("h1").size,
        canonical: doc.at_css("link[rel='canonical']")&.[]("href").to_s.strip,
        noindex: robots.any? { |c| c.include?("noindex") } || response.headers["x-robots-tag"].to_s.downcase.include?("noindex"),
        schema_types: doc.css("script[type='application/ld+json']").flat_map { |s| s.text.scan(/"@type"\s*:\s*"([A-Za-z]+)"/).flatten }.uniq,
        links: internal_paths(doc)
      }
    end

    def page_issues(page)
      url = page[:url]
      title = page[:title]
      path = path_of(url)
      out = []
      out << issue("noindex", url, title) if page[:noindex]
      out << issue("hidden_in_sitemap", url, title) if path.match?(%r{/pages/hidden|preview}i)

      longest = page[:descriptions].map(&:length).max.to_i
      if longest.zero?
        out << issue("missing_description", url, title)
      elsif longest > DESCRIPTION_BLOAT
        out << issue("no_seo_description", url, title, "#{longest} 字")
      end

      out << issue("long_title", url, title, "#{title.length} 字") if title.length > TITLE_MAX
      out << issue("missing_h1", url, title) if page[:h1].zero?
      out << issue("multiple_h1", url, title, "#{page[:h1]} 個") if page[:h1] > 1
      out << issue("missing_canonical", url, title) if page[:canonical].empty?
      out << issue("missing_product_schema", url, title) if path.include?("/products/") && !page[:schema_types].include?("Product")
      if path.match?(%r{/blog/posts/}) && (page[:schema_types] & %w[BlogPosting Article NewsArticle]).empty?
        out << issue("missing_article_schema", url, title)
      end
      out
    end

    def duplicate_title_issues(pages)
      pages.reject { |p| p[:title].empty? }.group_by { |p| p[:title] }.values.select { |g| g.size > 1 }.flat_map do |group|
        group.map { |p| issue("duplicate_title", p[:url], p[:title], "共 #{group.size} 頁同標題") }
      end
    end

    # 頁面上連到的站內網址，不在 sitemap 的才實際去讀（sitemap 裡的已經讀過了）
    def broken_link_issues(pages, sitemap)
      known = sitemap.map { |u| normalize(path_of(u)) }.to_set
      first_source = {}
      pages.each do |p|
        p[:links].each { |link| first_source[link] ||= p unless known.include?(normalize(link)) }
      end

      base = Sites::ALL.fetch(SITE)[:base_url]
      first_source.first(MAX_LINK_CHECKS).filter_map do |link, source|
        response = fetch(escape("#{base}#{link}"))
        next if response.nil? || response.code == 200 || (300..399).cover?(response.code)

        detail = response.code.zero? ? response.body : "HTTP #{response.code}"
        issue("broken_link", "#{base}#{link}", source[:title], "#{detail}；出現在 #{path_of(source[:url])}")
      end
    end

    # /en/ 版本若還開著、內容又是中文，等於整站重複一份
    def multilang_issues(base)
      response = fetch("#{base}/en/")
      return [] unless response&.code == 200

      doc = Nokogiri::HTML(response.body)
      return [] if doc.css("link[rel='alternate'][hreflang]").any?

      [issue("multilang_duplicate", "#{base}/en/", doc.at_css("title")&.text.to_s.strip,
             "/en/ 仍可開啟、沒有 hreflang，Google 會當成重複頁面；建議在後台關閉英文版")]
    end

    # 同一頁可能寫成 /products/x、/zh-hant/products/x
    def self.page_key(url)
      path = begin
        CGI.unescape(URI.parse(url.to_s.gsub(/[^\x00-\x7F]+/) { |m| CGI.escape(m) }).path.to_s)
      rescue URI::InvalidURIError
        url.to_s
      end
      path.sub(%r{\A/(?:zh-hant|en)(?=/|\z)}, "").chomp("/").presence || "/"
    end

    private

    def issue(type, url, title, detail = nil)
      { "type" => type, "url" => url, "title" => title.to_s.truncate(40), "detail" => detail }
    end

    def internal_paths(doc)
      doc.css("a[href]").filter_map do |a|
        href = a["href"].to_s.strip
        next if href.empty? || href.start_with?("#", "mailto:", "tel:", "javascript:")

        uri = URI.parse(escape(href))
        next unless uri.host.nil? || uri.host == "www.yardley.tw" || uri.host == "yardley.tw"
        next if uri.path.blank? || uri.path == "/"

        path = CGI.unescape(uri.path).chomp("/")
        next if path.sub(%r{\A/(?:zh-hant|en)}, "").match?(SKIP_LINK)

        path
      rescue URI::InvalidURIError
        nil
      end.uniq
    end

    def path_of(url)
      CGI.unescape(URI.parse(escape(url)).path.to_s)
    rescue URI::InvalidURIError
      url
    end

    # 同一頁可能寫成 /products/x、/zh-hant/products/x
    def normalize(path)
      path.sub(%r{\A/(?:zh-hant|en)(?=/|\z)}, "").chomp("/").presence || "/"
    end

    # sitemap 和連結裡的中文路徑要編碼才能發請求；已經編碼過的 % 不動
    def escape(url)
      url.gsub(/[^\x00-\x7F]+/) { |m| CGI.escape(m) }.gsub(" ", "%20")
    end
  end
end
