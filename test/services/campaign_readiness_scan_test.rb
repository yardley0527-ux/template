# frozen_string_literal: true

require "test_helper"

class CampaignReadinessScanTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 7, 13, 8, 0, 0)

    whitening = CrmProduct.create!(key: "whitening", label: "美白", status: "confirmed", include_in_analysis: true)
    whitening.crm_product_aliases.create!(alias_name: "美白錠", status: "active", source: "seed")
    CrmProduct.create!(key: "collagen_t", label: "膠原蛋白", status: "confirmed", include_in_analysis: true)

    @live = CalendarEvent.create!(title: "品牌之夜：美白", event_type: "livestream",
                                  event_date: Date.new(2026, 7, 17))
  end

  teardown { travel_back }

  test "resolves products from title and finds department mentions with evidence" do
    DepartmentUpdate.create!(department: "設計部", log_date: Date.current,
                             content: "【官網】美白圖卡 x3 已交檔\n【備註】協助會計簽名圖檔")
    DepartmentUpdate.create!(department: "社群部", log_date: Date.current - 1,
                             content: "美白錠衛教貼文已排程")
    DepartmentUpdate.create!(department: "物流部", log_date: Date.current,
                             content: "出貨 13 筆")

    radar = CampaignReadinessScan.call

    assert_equal @live, radar[:livestream]
    assert_equal ["美白"], radar[:products]

    by_dept = radar[:departments].index_by { |d| d[:department] }
    assert_equal 1, by_dept["設計部"][:mentions]
    assert_includes by_dept["設計部"][:evidence].first[:line], "美白圖卡"
    assert_equal 1, by_dept["社群部"][:mentions], "alias 美白錠 也要比對到"
    assert_equal 0, by_dept["物流部"][:mentions]
  end

  test "logs older than lookback window are ignored" do
    DepartmentUpdate.create!(department: "廣告部", log_date: Date.current - 5,
                             content: "美白推播圖完成")

    by_dept = CampaignReadinessScan.call[:departments].index_by { |d| d[:department] }
    assert_equal 0, by_dept["廣告部"][:mentions]
  end

  test "returns nil when no upcoming livestream" do
    CalendarEvent.delete_all
    assert_nil CampaignReadinessScan.call
  end

  test "title with no known product yields empty departments" do
    @live.update!(title: "品牌之夜（品項未定）", external_key: nil)

    radar = CampaignReadinessScan.call
    assert_empty radar[:products]
    assert_empty radar[:departments]
  end
end
