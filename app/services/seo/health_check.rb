# frozen_string_literal: true

require "net/http"
require "openssl"

module Seo
  # 每天自己掃一遍兩個網站：以前 SEO 公司在盯，現在沒人看，網站被誤加 noindex
  # 或首頁掛掉可能好幾週都沒人發現。
  #
  # 每項檢查回傳 { "check", "label", "url", "level", "detail" }，level：
  #   critical — 會讓網站從 Google 消失或打不開（noindex、首頁非 200、robots 全擋）
  #   warning  — 確定傷 SEO、該修的（description 爆量、Schema 重複、www 重複網站）
  #   info     — 只顯示在報告頁，不推通知板（圖片 alt 覆蓋率、description 略長）
  #   ok
  # 只有 critical/warning 會被 NotificationRules::SeoHealth 推到營運提醒。
  class HealthCheck
    LEVELS = %w[critical warning info ok].freeze
    USER_AGENT = "Mozilla/5.0 (compatible; YardleySeoMonitor/1.0)"
    # Shopline 短時間連續請求會回這個擋爬頁面（HTTP 200），不能當成網站內容判斷
    BUSY_MARKER = "The site is now busy"
    REQUEST_GAP = 2 # 秒，每個請求之間的間隔
    SAMPLE_PAGES = 4
    DESCRIPTION_MAX = 160
    # Shopline 沒填 SEO 描述時會直接截取商品內文前 300 字當 description，
    # 超過 250 字幾乎都是這種情況（正常手寫的 SEO 描述不會這麼長）
    DESCRIPTION_BLOAT = 250

    Response = Struct.new(:code, :body, :headers, :location, keyword_init: true)

    def initialize(date: Date.current, fetcher: nil, sleeper: ->(s) { sleep(s) })
      @date = date
      @fetcher = fetcher || method(:http_get)
      @sleeper = sleeper
    end

    def call(site)
      config = Sites::ALL.fetch(site)
      base = config[:base_url]
      results = []

      home = fetch("#{base}/")
      results.concat(page_checks(home, "#{base}/", homepage: true))
      results.concat(robots_checks(base))
      sitemap_urls = sitemap_page_urls(base, results)
      sample_urls(sitemap_urls, base).each do |url|
        results.concat(page_checks(fetch(url), url, homepage: false))
      end
      results << llms_check(base)
      config[:redirect_hosts].each { |host| results << redirect_check(host, base) }
      results << ssl_check(URI(base).host)
      results
    end

    # ---- 頁面層級 ----

    def page_checks(response, url, homepage:)
      prefix = homepage ? "首頁" : "抽查頁"
      return [result("page_status", "#{prefix}可連線", url, "info", "網站回擋爬頁面，今天無法檢查")] if response.nil?

      unless response.code == 200
        level = homepage ? "critical" : "warning"
        detail = response.code.zero? ? response.body : "HTTP #{response.code}"
        return [result("page_status", "#{prefix}可連線", url, level, detail)]
      end

      doc = Nokogiri::HTML(response.body)
      checks = [noindex_check(doc, response, url, prefix), description_check(doc, url, prefix), canonical_check(doc, url, prefix)]
      if homepage
        checks << organization_schema_check(doc, url)
        checks << h1_check(doc, url)
        checks << alt_check(doc, url)
      end
      checks
    end

    def noindex_check(doc, response, url, prefix)
      meta = doc.css("meta[name='robots'], meta[name='googlebot']").map { |m| m["content"].to_s.downcase }
      header = response.headers["x-robots-tag"].to_s.downcase
      if meta.any? { |c| c.include?("noindex") } || header.include?("noindex")
        result("noindex", "#{prefix}沒有 noindex", url, "critical", "meta robots／X-Robots-Tag 含 noindex，頁面將被移出索引")
      else
        result("noindex", "#{prefix}沒有 noindex", url, "ok", nil)
      end
    end

    def description_check(doc, url, prefix)
      descriptions = doc.css("meta[name='description']").map { |m| m["content"].to_s.strip }
      label = "#{prefix} Meta Description"
      return result("meta_description", label, url, "warning", "缺少 meta description") if descriptions.empty? || descriptions.all?(&:empty?)

      longest = descriptions.map(&:length).max
      if descriptions.size > 1
        result("meta_description", label, url, "warning", "重複輸出 #{descriptions.size} 組 description")
      elsif longest > DESCRIPTION_BLOAT
        result("meta_description", label, url, "warning", "#{longest} 字，超過 #{DESCRIPTION_MAX} 字上限；未設定 SEO 描述，系統自動截取頁面內文")
      elsif longest > DESCRIPTION_MAX
        result("meta_description", label, url, "info", "長度 #{longest} 字，略超過 #{DESCRIPTION_MAX} 字")
      else
        result("meta_description", label, url, "ok", "長度 #{longest} 字")
      end
    end

    def canonical_check(doc, url, prefix)
      canonical = doc.at_css("link[rel='canonical']")&.[]("href")
      label = "#{prefix} Canonical"
      return result("canonical", label, url, "warning", "缺少 canonical 標籤") if canonical.blank?

      if URI(canonical).host != URI(url).host
        result("canonical", label, url, "warning", "canonical 指向其他網域：#{canonical}")
      else
        result("canonical", label, url, "ok", nil)
      end
    rescue URI::InvalidURIError
      result("canonical", label, url, "warning", "canonical 網址格式錯誤：#{canonical}")
    end

    def organization_schema_check(doc, url)
      count = doc.css("script[type='application/ld+json']").sum { |s| s.text.scan(/"@type"\s*:\s*"Organization"/).size }
      if count > 1
        result("organization_schema", "Organization Schema", url, "warning", "重複輸出 #{count} 組，需移除主題預設的那組")
      elsif count.zero?
        result("organization_schema", "Organization Schema", url, "info", "首頁沒有 Organization Schema")
      else
        result("organization_schema", "Organization Schema", url, "ok", nil)
      end
    end

    def h1_check(doc, url)
      count = doc.css("h1").size
      level = count.zero? ? "warning" : (count > 1 ? "info" : "ok")
      result("h1", "首頁 H1", url, level, count.zero? ? "缺少 H1" : "#{count} 個 H1")
    end

    def alt_check(doc, url)
      images = doc.css("img")
      return result("image_alt", "首頁圖片 Alt", url, "ok", "沒有圖片") if images.empty?

      with_alt = images.count { |img| img["alt"].to_s.strip.present? }
      ratio = (with_alt * 100.0 / images.size).round
      level = ratio >= 95 ? "ok" : "info"
      result("image_alt", "首頁圖片 Alt", url, level, "#{with_alt}/#{images.size} 張有 alt（#{ratio}%，目標 95%）")
    end

    # ---- 網站層級 ----

    def robots_checks(base)
      url = "#{base}/robots.txt"
      response = fetch(url)
      return [result("robots", "robots.txt", url, "info", "今天無法取得")] if response.nil?
      return [result("robots", "robots.txt", url, "warning", "HTTP #{response.code}")] unless response.code == 200

      blocked = robots_blocks_google?(response.body)
      [result("robots", "robots.txt", url, blocked ? "critical" : "ok",
              blocked ? "User-agent: * 為 Disallow: /，全站禁止爬取" : nil)]
    end

    # 只看套用到 Googlebot 的群組（User-agent: * 或 googlebot）。Shopline 的 robots.txt
    # 會對 MJ12bot 等特定爬蟲寫 Disallow: /，那是正常的。
    def robots_blocks_google?(text)
      groups = []
      current = nil
      text.each_line do |raw|
        line = raw.sub(/#.*/, "").strip
        next if line.empty?

        field, value = line.split(":", 2).map { |part| part.to_s.strip }
        case field.downcase
        when "user-agent"
          current = nil if current && current[:rules].any?
          current ||= { agents: [], rules: [] }.tap { |g| groups << g }
          current[:agents] << value.downcase
        when "allow", "disallow"
          current[:rules] << [field.downcase, value] if current
        end
      end

      google = groups.select { |g| g[:agents].include?("googlebot") }
      google = groups.select { |g| g[:agents].include?("*") } if google.empty?
      google.any? { |g| g[:rules].include?(["disallow", "/"]) && !g[:rules].include?(["allow", "/"]) }
    end

    def sitemap_page_urls(base, results)
      url = "#{base}/sitemap.xml"
      response = fetch(url)
      if response.nil?
        results << result("sitemap", "Sitemap", url, "info", "今天無法取得")
        return []
      end
      unless response.code == 200 && response.body.include?("<")
        results << result("sitemap", "Sitemap", url, "warning", "HTTP #{response.code}")
        return []
      end

      locs = xml_locs(response.body)
      if response.body.include?("<sitemapindex")
        child = locs.find { |l| l.include?("zh-hant") } || locs.find { |l| l.include?("post") } || locs.first
        child_response = child && fetch(child)
        locs = child_response&.code == 200 ? xml_locs(child_response.body) : []
      end
      results << result("sitemap", "Sitemap", url, locs.any? ? "ok" : "warning",
                        locs.any? ? "#{locs.size} 個網址" : "sitemap 裡沒有任何網址")
      locs
    end

    # 每天抽不同的頁（以日期當亂數種子），長期下來會輪到大部分頁面；
    # 有商品頁就優先抽商品頁（yardley 的 description 爆量問題出在商品頁）。
    def sample_urls(urls, base)
      candidates = urls.reject { |u| u.chomp("/") == base }
      products = candidates.select { |u| u.include?("/products/") }
      pool = products.any? ? products : candidates
      pool.sample(SAMPLE_PAGES, random: Random.new(@date.jd))
    end

    def llms_check(base)
      url = "#{base}/llms.txt"
      response = fetch(url)
      if response&.code == 200 && !response.body.lstrip.start_with?("<")
        result("llms_txt", "llms.txt", url, "ok", nil)
      else
        result("llms_txt", "llms.txt", url, "info", response ? "尚未上線（HTTP #{response.code}）" : "今天無法取得")
      end
    end

    def redirect_check(host, base)
      url = "https://#{host}/"
      response = fetch(url)
      target_host = URI(base).host
      return result("redirect", "#{host} 轉址", url, "info", "今天無法取得") if response.nil?

      if [301, 308].include?(response.code) && URI(response.location.to_s).host == target_host
        result("redirect", "#{host} 轉址", url, "ok", "301 → #{target_host}")
      elsif response.code == 200
        result("redirect", "#{host} 轉址", url, "warning",
               "未 301 至 #{target_host}，兩個主機名稱重複收錄")
      elsif response.code.zero?
        result("redirect", "#{host} 轉址", url, "warning", "https://#{host} #{response.body}")
      else
        result("redirect", "#{host} 轉址", url, "info", "HTTP #{response.code} → #{response.location}")
      end
    rescue URI::InvalidURIError
      result("redirect", "#{host} 轉址", url, "info", "轉址目標格式錯誤")
    end

    def ssl_check(host)
      days = ssl_days_left(host)
      level = if days < 7 then "critical" elsif days < 21 then "warning" else "ok" end
      result("ssl", "SSL 憑證", "https://#{host}/", level, "還有 #{days} 天到期")
    rescue StandardError => e
      result("ssl", "SSL 憑證", "https://#{host}/", "info", "無法檢查：#{e.class}")
    end

    private

    def result(check, label, url, level, detail)
      { "check" => check, "label" => label, "url" => url, "level" => level, "detail" => detail }
    end

    def xml_locs(body)
      body.scan(%r{<loc>\s*(?:<!\[CDATA\[)?\s*(.*?)\s*(?:\]\]>)?\s*</loc>}m).flatten.map { |u| CGI.unescapeHTML(u) }
    end

    # 回傳 Response，或 nil（連續被擋爬頁面擋下，今天無法判斷 → 不該誤報成網站壞掉）
    # 連線錯誤也重試；三次都連不上回傳 code 0（網站真的掛了就該報警）。
    def fetch(url)
      error = nil
      3.times do |attempt|
        @sleeper.call(attempt.zero? ? REQUEST_GAP : REQUEST_GAP * 5)
        begin
          response = @fetcher.call(url)
          return response unless response.code == 200 && response.body.to_s.include?(BUSY_MARKER)

          error = nil
        rescue StandardError => e
          error = e
        end
      end
      return nil unless error

      Rails.logger.warn("[seo] fetch #{url}: #{error.class} #{error.message}")
      Response.new(code: 0, body: connection_error_detail(error), headers: {}, location: nil)
    end

    def connection_error_detail(error)
      return "SSL 憑證無效（#{error.message.split(':').last.strip}），需補發憑證或改由 DNS 層轉址" if error.is_a?(OpenSSL::SSL::SSLError)

      "連線失敗（#{error.class.name.demodulize}）"
    end

    def http_get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = http.request(request)
      body = response.body.to_s.dup.force_encoding("UTF-8")
      Response.new(code: response.code.to_i, body: body,
                   headers: response.to_hash.transform_values { |v| v.join(", ") },
                   location: response["location"])
    end

    def ssl_days_left(host)
      tcp = Socket.tcp(host, 443, connect_timeout: 10)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new)
      ssl.hostname = host
      ssl.connect
      ((ssl.peer_cert.not_after - Time.now) / 1.day).floor
    ensure
      ssl&.close
      tcp&.close
    end
  end
end
