# frozen_string_literal: true

require "test_helper"

module Seo
  class ArticleReviewTest < ActiveSupport::TestCase
    def review_with(post_html, title:, page_html: "<meta name='description' content='短描述'>")
      posts = [{ "id" => 7, "date" => "2026-10-19T09:00:00", "link" => "https://shengtingbio.com/a/",
                 "title" => { "rendered" => title }, "content" => { "rendered" => post_html } }]
      fetcher = ->(url) { url.include?("wp-json") ? posts.to_json : page_html }
      ArticleReview.new(date: Date.new(2026, 10, 20), fetcher: fetcher).call.first
    end

    test "依改寫規則抓出問題" do
      html = "<p>近年來大家都在討論。</p>#{'<table></table>' * 3}<h2>常見問題 FAQ（10 題）</h2><img src='x.png'>"
      flags = review_with(html, title: "PDRN 成分全解析")["flags"]

      assert_includes flags, "標題不是問句"
      assert_includes flags, "表格 3 個（上限 2）"
      assert_includes flags, "FAQ 只有 10 題（建議 15–20 題）"
      assert_includes flags, "沒有連到 yardley 商品頁"
      refute flags.any? { |f| f.include?("alt") }, "編輯不放 alt，不該檢查"
    end

    test "沒有寫題數時數 FAQ 底下的問句小標" do
      faqs = (1..16).map { |i| "<h3>問題#{i}？</h3><p>答</p>" }.join
      html = "<p>PDRN 是 DNA 片段。</p><h2>常見問題</h2>#{faqs}<a href='https://www.yardley.tw/products/x'>買</a>"
      result = review_with(html, title: "PDRN 是什麼？")

      assert_equal 16, result["faq_count"]
      assert_empty result["flags"]
    end

    test "問號在中間（問句＋副標）也算問句" do
      flags = review_with("<p>不是。</p>", title: "鮭魚 DNA 與 PDRN 是一樣的東西嗎？破解原料來源迷思")["flags"]

      assert_not_includes flags, "標題不是問句"
    end

    test "週一要看週五到週日" do
      assert_equal Date.new(2026, 10, 16)...Date.new(2026, 10, 19), ArticleReview.new(date: Date.new(2026, 10, 19)).window
    end
  end
end
