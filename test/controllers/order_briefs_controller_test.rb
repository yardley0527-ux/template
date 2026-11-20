# frozen_string_literal: true

require "test_helper"

class OrderBriefsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DAY = Date.new(2026, 10, 22)

  setup do
    @old_ai = ENV.delete("ANTHROPIC_API_KEY") # 不打真的 AI
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "brief-admin@test.com", username: "brief_admin", password: "password123", role: admin_role)
    ShoplineCustomer.create!(email: "amy@example.com", full_name: "Amy", membership_level: "黑卡")
    ShoplineOrder.create!(order_number: "#A1", email: "amy@example.com", product_name: "PDRN3", quantity: 1, total_amount: 9000,
                          checkout_amount: 9000, payment_status: "已付款", order_date: Time.zone.local(2026, 9, 20, 12))
    ShoplineOrder.create!(order_number: "#A2", email: "amy@example.com", product_name: "PDRN6", quantity: 1, total_amount: 20_000,
                          checkout_amount: 20_000, payment_status: "已付款", order_date: Time.zone.local(2026, 10, 22, 12))
  end

  teardown { ENV["ANTHROPIC_API_KEY"] = @old_ai if @old_ai }

  test "第一次進來只有表單，選日期才產生；文字有複製按鈕、表格直接畫在網頁上" do
    sign_in @admin
    get order_briefs_path
    assert_response :ok
    assert_includes response.body, "產生簡報"
    assert_not_includes response.body, "訂單簡報\n"

    get order_briefs_path, params: { date: DAY.iso8601, ai: "1" }
    assert_response :ok
    assert_includes response.body, "10/22 訂單簡報"
    assert_includes response.body, "複製"
    assert_includes response.body, "回購 PDRN"
    assert_includes response.body, "Amy"
  end

  test "產生銷售日報：每段可複製，也可以全部複製" do
    sign_in @admin
    get order_briefs_path, params: { date: DAY.iso8601, report: "sales" }
    assert_response :ok
    assert_includes response.body, "10/22 銷售日報"
    assert_includes response.body, "全部複製"
    assert_includes response.body, "SL 訂單"
    assert_includes response.body, "月累計"
    assert_not_includes response.body, "回購 PDRN" # 不是訂單簡報
    assert_not_includes response.body, %(class="js-sales-chart") # 一天不畫圖

    get order_briefs_path, params: { date_from: (DAY - 2).iso8601, date: DAY.iso8601, report: "sales" }
    assert_response :ok
    assert_includes response.body, "10/20–10/22 銷售日報"
    assert_equal 4, response.body.scan('class="js-sales-chart"').size # 訂單、卡別、年齡層、熱銷
    assert_includes response.body, "每天營收（舊客／新客）"

    get order_briefs_path, params: { date_from: "2026-09-01", date: "2026-09-02", report: "sales" }
    assert_includes response.body, "沒有已付款訂單"
  end

  test "每日報告選區間：多天合併成一份，新舊客和隔幾天看區間內第一張單" do
    ShoplineCustomer.create!(email: "bea@example.com", full_name: "Bea")
    ShoplineOrder.create!(order_number: "#B1", email: "bea@example.com", product_name: "PDRN1", quantity: 1, total_amount: 3000,
                          checkout_amount: 3000, payment_status: "已付款", order_date: Time.zone.local(2026, 10, 20, 12))
    ShoplineOrder.create!(order_number: "#B2", email: "bea@example.com", product_name: "PDRN3", quantity: 1, total_amount: 9000,
                          checkout_amount: 9000, payment_status: "已付款", order_date: Time.zone.local(2026, 10, 21, 12))
    sign_in @admin

    get order_briefs_path, params: { date_from: "2026-10-20", date: "2026-10-22" }
    assert_response :ok
    assert_includes response.body, "10/20–10/22 訂單簡報"
    assert_includes response.body, "共 2 人下單、3 張單，營收 $32,000"
    assert_includes response.body, "新客 1 人、2 張單" # Bea 兩張單都在區間內，仍是新客
    assert_includes response.body, "這段期間買"
    assert_includes response.body, "32 天" # Amy 從 10/22 往回算到 9/20

    get order_briefs_path, params: { date_from: "2026-10-20", date: "2026-10-22", report: "sales" }
    assert_includes response.body, "10/20–10/22 銷售日報"
  end

  test "區間開始晚於結束、或超過 31 天會提示" do
    sign_in @admin
    get order_briefs_path, params: { date_from: "2026-10-23", date: "2026-10-22" }
    assert_includes response.body, "結束日期不能早於開始日期"
    get order_briefs_path, params: { date_from: "2026-09-01", date: "2026-10-22" }
    assert_includes response.body, "一次最多跑 31 天"
  end

  test "那天沒有訂單就說沒有" do
    sign_in @admin
    get order_briefs_path, params: { date: "2026-10-01" }
    assert_includes response.body, "10/1 沒有已付款訂單"
  end

  test "產生 SEO 日報：選昨天會拿到今天早上那份，不需要有訂單" do
    SeoReport.create!(report_date: Date.new(2026, 10, 2), status: "success", data: {
      "sites" => { "yardley" => { "data_through" => "2026-09-29", "summary" => { "clicks" => 708 } } }
    })
    sign_in @admin
    get order_briefs_path, params: { date: "2026-10-01", report: "seo", ai: "1" }
    assert_response :ok
    assert_includes response.body, "10/2 SEO 日報"
    assert_includes response.body, "yardley.tw 本週點擊 708"
    assert_not_includes response.body, "沒有已付款訂單"

    get order_briefs_path, params: { date: "2026-09-01", report: "seo" }
    assert_includes response.body, "9/2 以前沒有成功的 SEO 報告"
  end

  test "AI 暫停時，SEO 日報照樣顯示手寫重點（manual_ai）" do
    ENV.delete("AI_REPORTS_ENABLED")
    SeoReport.create!(report_date: Date.new(2026, 10, 2), status: "success", data: {
      "sites" => { "yardley" => { "data_through" => "2026-09-29", "summary" => { "clicks" => 708 } } },
      "manual_ai" => { "highlights" => ["手寫重點"], "article_comments" => [], "suggestion" => "手寫建議" }
    })
    sign_in @admin
    get order_briefs_path, params: { date: "2026-10-01", report: "seo" }
    assert_includes response.body, "1. 手寫重點"
    assert_not_includes response.body, "發到 LINE"
  end

  test "有存手寫重點的日子，訂單簡報直接顯示重點（不用勾 AI、不打 API）" do
    OrderBriefNote.create!(report_date: DAY, highlights: [{ "title" => "手寫結論", "details" => ["手寫補充"] }])
    sign_in @admin
    get order_briefs_path, params: { date: DAY.iso8601 }
    assert_includes response.body, "1. 手寫結論"
    assert_includes response.body, "- 手寫補充"

    get order_briefs_path, params: { date_from: (DAY - 1).iso8601, date: DAY.iso8601 }
    assert_not_includes response.body, "手寫結論" # 區間報告不套單日重點
  end

  test "黑金卡回來了、生日名單可以直接在網頁產生" do
    sign_in @admin
    get order_briefs_path, params: { date: DAY.iso8601, report: "returns" }
    assert_response :ok
    assert_includes response.body, "10/22 久未消費黑金卡回來了"
    assert_includes response.body, "這天沒有符合的客人"

    get order_briefs_path, params: { date: DAY.iso8601, report: "birthdays" }
    assert_response :ok
    assert_includes response.body, "生日名單"
    assert_includes response.body, "黑金卡本週生日"
  end

  test "區間報告都跑得出來；表格可複製" do
    sign_in @admin
    { "hours" => "業績時段分佈", "profile" => "客群輪廓", "products" => "產品銷售", "payments" => "付款方式" }.each do |report, title|
      get order_briefs_path, params: { from: "2026-10-01", to: DAY.iso8601, report: report }
      assert_response :ok
      assert_includes response.body, "10/1–10/22 #{title}"
      assert_includes response.body, "複製表格"
    end
  end

  test "區間報告：沒訂單、日期相反、區間太長都提示" do
    sign_in @admin
    get order_briefs_path, params: { from: "2026-08-01", to: "2026-08-02", report: "hours" }
    assert_includes response.body, "8/1–8/2 沒有符合的已付款訂單"
    get order_briefs_path, params: { from: "2026-10-02", to: "2026-10-01", report: "hours" }
    assert_includes response.body, "結束日期不能早於開始日期"
    get order_briefs_path, params: { from: "2024-01-01", to: "2026-10-01", report: "hours" }
    assert_includes response.body, "一次最多跑 400 天"
  end

  test "沒回來名單要有產品，結果回報黑名單" do
    sign_in @admin
    get order_briefs_path, params: { report: "unrepurchased", product_list: " " }
    assert_includes response.body, "請輸入產品關鍵字"

    get order_briefs_path, params: { report: "unrepurchased", product_list: "PDRN", list_from: "2026-10-01", list_to: DAY.iso8601,
                                     audience: "all", min_amount: "0", skip_days: "0" }
    assert_response :ok
    assert_includes response.body, "PDRN 買家沒回來名單"
    assert_includes response.body, "已檢查黑名單，0 人命中"
    assert_includes response.body, "Amy"
  end

  test "分頁：跑完留在同一頁，顯示目前報告，其他分頁的條件不清掉" do
    sign_in @admin
    get order_briefs_path
    assert_select "#report-tab-daily.active"
    assert_select "#report-result", 0

    get order_briefs_path, params: { from: "2026-10-01", to: DAY.iso8601, product: "PDRN", report: "hours", list_from: "2026-09-01" }
    assert_select "#report-tab-range.active"
    assert_select "#report-result"
    assert_includes response.body, "目前報告：<strong>業績時段＋新舊客</strong>｜10/1–10/22｜只看 PDRN"
    assert_select "#report-tab-daily form input[type=hidden][name=product][value=PDRN]"
    assert_select "#report-tab-range form input[type=hidden][name=list_from][value=?]", "2026-09-01"

    get order_briefs_path, params: { report: "unrepurchased", product_list: "PDRN", list_from: "2026-10-01", list_to: DAY.iso8601 }
    assert_select "#report-tab-list.active"

    get order_briefs_path, params: { date: DAY.iso8601, report: "returns" }
    assert_select "#report-tab-daily.active"
  end

  test "黑金卡回來了是每日報告的按鈕；星期一選昨天看五到日" do
    sign_in @admin
    get order_briefs_path
    assert_select "#report-tab-daily button[value=returns]", text: "黑金卡回來了"
    assert_not_includes response.body, "產生通知"

    travel_to Time.zone.local(2026, 11, 2, 11) do
      get order_briefs_path, params: { date: "2026-11-01", report: "returns" }
      assert_includes response.body, "10/30–11/1 久未消費黑金卡回來了"
    end
  end

  test "Claude SEO 外掛每週報告：顯示最新一份可複製，沒有就說還沒有" do
    sign_in @admin
    get order_briefs_path, params: { report: "seo_weekly", date: "2026-11-19" }
    assert_includes response.body, "還沒有每週報告"

    SeoSiteAudit.create!(site: "yardley", audited_on: Date.new(2026, 11, 20), pages_checked: 519,
                         issues: [{ "type" => "noindex", "url" => "https://www.yardley.tw/pages/a", "title" => "優惠頁", "detail" => nil }])
    get order_briefs_path, params: { report: "seo_weekly", date: "2026-11-19" }
    assert_response :ok
    assert_includes response.body, "Claude SEO 外掛每週報告"
    assert_includes response.body, "seo-weekly-text"
    assert_includes response.body, "優惠頁"
  end

  test "廣告週報：沒填 Meta 數字時說還沒填，填了就帶出花費、每位追蹤成本和單一廣告重點" do
    sign_in @admin
    get order_briefs_path, params: { report: "ads_weekly", date: "2026-11-17" }
    assert_response :ok
    assert_includes response.body, "ads-weekly-text"
    assert_includes response.body, "11/11–11/17"
    assert_includes response.body, "Meta 數字還沒填"

    AdWeeklyMetric.create!(week_end: Date.new(2026, 11, 17), spend: 72_520, ad_follows: 387, notes: ["FB 版位花 33%，排除 FB"])
    get order_briefs_path, params: { report: "ads_weekly", date: "2026-11-17" }
    assert_includes response.body, "$72,520"
    assert_includes response.body, "每位 $187"
    assert_includes response.body, "FB 版位花 33%"
  end
end
