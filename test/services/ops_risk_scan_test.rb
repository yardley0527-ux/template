# frozen_string_literal: true

require "test_helper"

class OpsRiskScanTest < ActiveSupport::TestCase
  setup { travel_to Time.zone.local(2026, 7, 13, 8, 0, 0) }
  teardown { travel_back }

  test "flags department silent for the last two reporting days" do
    # 7/10、7/13 是全公司有回報的日子；廣告部兩天都沒寫
    %w[設計部 物流部].each do |dept|
      DepartmentUpdate.create!(department: dept, log_date: Date.new(2026, 7, 10), content: "工作")
      DepartmentUpdate.create!(department: dept, log_date: Date.new(2026, 7, 13), content: "工作")
    end
    DepartmentUpdate.create!(department: "廣告部", log_date: Date.new(2026, 7, 9), content: "舊的")

    risks = OpsRiskScan.call
    assert(risks.any? { |r| r[:message].include?("廣告部") && r[:message].include?("連續 2 個回報日") })
    assert(risks.none? { |r| r[:message].include?("設計部已連續") })
  end

  test "no silent-department risk with fewer than two reporting days" do
    DepartmentUpdate.create!(department: "設計部", log_date: Date.current, content: "工作")
    assert_empty OpsRiskScan.call
  end

  test "flags undecided livestream within 30 days only" do
    CalendarEvent.create!(title: "品牌之夜（品項未定）", event_type: "livestream",
                          event_date: Date.current + 20)
    CalendarEvent.create!(title: "品牌之夜（品項未定）", event_type: "livestream",
                          event_date: Date.current + 60)

    risks = OpsRiskScan.call.select { |r| r[:message].include?("品項未定") }
    assert_equal 1, risks.size
    assert_includes risks.first[:message], "倒數 20 天"
  end

  test "flags out-of-stock product with livestream in window" do
    # JourneyProducts 目前 in_stock=false 且無 restock_date 的產品之一：全能
    entry = JourneyProducts::PRODUCTS.values.find { |p| p[:in_stock] == false && p[:restock_date].nil? }
    skip "JourneyProducts 目前沒有缺貨且無補貨日的產品" if entry.nil?

    CalendarEvent.create!(title: "品牌之夜：#{entry[:label]}", event_type: "livestream",
                          event_date: Date.current + 7)

    risks = OpsRiskScan.call
    assert(risks.any? { |r| r[:level] == "danger" && r[:message].include?("標記缺貨") })
  end

  test "flags restock date later than livestream date" do
    entry = JourneyProducts::PRODUCTS.values.find { |p| p[:restock_date].present? }
    skip "JourneyProducts 目前沒有設定補貨日的產品" if entry.nil?

    CalendarEvent.create!(title: "品牌之夜：#{entry[:label]}", event_type: "livestream",
                          event_date: entry[:restock_date] - 2)

    risks = OpsRiskScan.call
    assert(risks.any? { |r| r[:message].include?("晚於直播日") })
  end

  test "flags silent core departments when countdown is 3 days or less" do
    live = CalendarEvent.new(title: "品牌之夜：美白", event_type: "livestream",
                             event_date: Date.current + 2)
    radar = {
      livestream: live,
      products: ["美白"],
      departments: [
        { department: "設計部", mentions: 2, evidence: [] },
        { department: "廣告部", mentions: 0, evidence: [] },
        { department: "CRM",   mentions: 0, evidence: [] }
      ]
    }

    risks = OpsRiskScan.call(radar: radar)
    assert(risks.any? { |r| r[:message].include?("廣告部") && r[:message].include?("倒數 2 天") })
    assert(risks.none? { |r| r[:message].include?("設計部近 3 天") })
    assert(risks.none? { |r| r[:message].include?("CRM近 3 天") }, "非核心製作部門不觸發")
  end

  test "no core-dept risk when countdown exceeds 3 days" do
    live = CalendarEvent.new(title: "品牌之夜：美白", event_type: "livestream",
                             event_date: Date.current + 4)
    radar = { livestream: live, products: ["美白"],
              departments: [{ department: "廣告部", mentions: 0, evidence: [] }] }

    assert_empty OpsRiskScan.call(radar: radar)
  end
end
