# frozen_string_literal: true

require "test_helper"

module Seo
  class HealthCheckTest < ActiveSupport::TestCase
    R = HealthCheck::Response

    def page(body, code: 200, headers: {}, location: nil)
      R.new(code: code, body: body, headers: headers, location: location)
    end

    def html(description: "苼莛國際生技保健食品", extra_head: "", body: "<h1>苼莛</h1><img src='a.jpg' alt='a'>")
      "<html><head><meta name='description' content='#{description}'>" \
        "<link rel='canonical' href='https://www.yardley.tw/'>#{extra_head}</head><body>#{body}</body></html>"
    end

    def checker(responses)
      fetcher = ->(url) { responses.fetch(url) { page("", code: 404) } }
      HealthCheck.new(date: Date.new(2026, 10, 20), fetcher: fetcher, sleeper: ->(_) {})
    end

    def level(results, check)
      results.find { |r| r["check"] == check }&.fetch("level")
    end

    test "Shopline 對特定爬蟲的 Disallow: / 不算擋 Google" do
      robots = "User-agent: MJ12bot\nDisallow: /\n\nUser-agent: *\nDisallow: /users/\nSitemap: https://www.yardley.tw/sitemap.xml\n"
      refute HealthCheck.new.robots_blocks_google?(robots)
    end

    test "User-agent: * 全擋或 Googlebot 全擋要判定為擋 Google" do
      assert HealthCheck.new.robots_blocks_google?("User-agent: *\nDisallow: /\n")
      assert HealthCheck.new.robots_blocks_google?("User-agent: Googlebot\nUser-agent: Bingbot\nDisallow: /\n")
      refute HealthCheck.new.robots_blocks_google?("User-agent: *\nDisallow:\n")
    end

    test "noindex 是 critical" do
      results = checker({}).page_checks(page(html(extra_head: "<meta name='robots' content='noindex, follow'>")),
                                        "https://www.yardley.tw/", homepage: true)
      assert_equal "critical", level(results, "noindex")
    end

    test "X-Robots-Tag header 的 noindex 也要抓到" do
      results = checker({}).page_checks(page(html, headers: { "x-robots-tag" => "noindex" }), "https://www.yardley.tw/p", homepage: false)
      assert_equal "critical", level(results, "noindex")
    end

    test "description 爆量是 warning，略長只是 info" do
      bloated = checker({}).page_checks(page(html(description: "字" * 5560)), "https://www.yardley.tw/products/a", homepage: false)
      assert_equal "warning", level(bloated, "meta_description")

      long = checker({}).page_checks(page(html(description: "字" * 190)), "https://www.yardley.tw/", homepage: true)
      assert_equal "info", level(long, "meta_description")
    end

    test "Organization Schema 重複宣告是 warning" do
      schema = "<script type='application/ld+json'>{\"@type\": \"Organization\"}</script>"
      results = checker({}).page_checks(page(html(extra_head: schema * 2)), "https://www.yardley.tw/", homepage: true)
      assert_equal "warning", level(results, "organization_schema")
    end

    test "首頁打不開是 critical，抽查頁 404 是 warning" do
      assert_equal "critical", level(checker({}).page_checks(page("", code: 500), "https://x/", homepage: true), "page_status")
      assert_equal "warning", level(checker({}).page_checks(page("", code: 404), "https://x/a", homepage: false), "page_status")
    end

    test "連續被擋爬頁面擋下時不誤報，只記 info" do
      busy = page("<title>The site is now busy. Please try refreshing the page.</title>")
      hc = checker("https://www.yardley.tw/" => busy)
      results = hc.page_checks(hc.send(:fetch, "https://www.yardley.tw/"), "https://www.yardley.tw/", homepage: true)
      assert_equal "info", level(results, "page_status")
    end

    test "www 版本沒轉址是 warning，301 到主網域是 ok" do
      dup = checker("https://www.shengtingbio.com/" => page(html))
      assert_equal "warning", dup.redirect_check("www.shengtingbio.com", "https://shengtingbio.com")["level"]

      ok = checker("https://www.shengtingbio.com/" => page("", code: 301, location: "https://shengtingbio.com/"))
      assert_equal "ok", ok.redirect_check("www.shengtingbio.com", "https://shengtingbio.com")["level"]
    end

    test "不帶 www 的網址 SSL 憑證錯誤是 warning" do
      fetcher = ->(_url) { raise OpenSSL::SSL::SSLError, "certificate verify failed (self signed certificate)" }
      hc = HealthCheck.new(fetcher: fetcher, sleeper: ->(_) {})
      result = hc.redirect_check("yardley.tw", "https://www.yardley.tw")
      assert_equal "warning", result["level"]
      assert_match "SSL 憑證錯誤", result["detail"]
    end

    test "完整跑一站：sitemap index 會往下抓子 sitemap 並抽商品頁" do
      base = "https://www.yardley.tw"
      responses = {
        "#{base}/" => page(html),
        "#{base}/robots.txt" => page("User-agent: *\nDisallow: /users/\n"),
        "#{base}/sitemap.xml" => page("<sitemapindex><sitemap><loc>#{base}/sitemap.xml?locale=zh-hant</loc></sitemap></sitemapindex>"),
        "#{base}/sitemap.xml?locale=zh-hant" => page("<urlset><url><loc>#{base}/products/a</loc></url><url><loc>#{base}/pages/b</loc></url></urlset>"),
        "#{base}/products/a" => page(html(description: "字" * 400)),
        "#{base}/llms.txt" => page("# 苼莛"),
        "https://yardley.tw/" => page("", code: 301, location: "#{base}/")
      }
      hc = checker(responses)
      hc.define_singleton_method(:ssl_days_left) { |_host| 60 }
      results = hc.call("yardley")

      assert_equal "ok", level(results, "sitemap")
      assert(results.any? { |r| r["url"] == "#{base}/products/a" && r["level"] == "warning" })
      refute(results.any? { |r| r["url"] == "#{base}/pages/b" }, "有商品頁時只抽商品頁")
      assert_equal "ok", level(results, "redirect")
      assert_equal "ok", level(results, "ssl")
    end
  end
end
