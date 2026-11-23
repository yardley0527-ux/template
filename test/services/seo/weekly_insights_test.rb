# frozen_string_literal: true

require "test_helper"

class Seo::WeeklyInsightsTest < ActiveSupport::TestCase
  class FakeGsc
    PAGE = "https://www.yardley.tw/blog/posts/a"

    def latest_date(_site) = Date.new(2026, 11, 17)

    def rows(_site, _range, dimensions, **)
      if dimensions == ["page"]
        [{ "keys" => [PAGE], "impressions" => 5000, "clicks" => 20, "ctr" => 0.004, "position" => 8.0 }]
      else
        [{ "keys" => ["全身無力", PAGE], "impressions" => 500, "clicks" => 2, "ctr" => 0.004, "position" => 7.9 }]
      end
    end

    def movers(*, **) = { "pages" => { "drops" => [] } }

    def page_queries(_site, page, _range)
      raise "boom" unless page == PAGE

      [["全身無力", 504, 2, 7.9]]
    end
  end

  test "每一頁附上實際被搜的關鍵字" do
    out = Seo::WeeklyInsights.new(search_console: FakeGsc.new).call
    assert_equal [FakeGsc::PAGE], Seo::WeeklyInsights.referenced_pages(out)
    assert_equal [["全身無力", 504, 2, 7.9]], out["page_queries"][FakeGsc::PAGE]
  end
end
