# frozen_string_literal: true

require "test_helper"

class LivestreamsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "admin-ls@test.com", username: "admin_ls", password: "password123", role: admin_role)

    @staff_role = Role.create!(key: "staff-ls-#{SecureRandom.hex(4)}", name: "Staff")
    @staff = User.create!(email: "staff-ls@test.com", username: "staff_ls", password: "password123", role: @staff_role)

    turmeric = CrmProduct.find_or_create_by!(key: "turmeric") { |c| c.label = "薑黃"; c.status = "confirmed"; c.include_in_analysis = true }
    CrmProduct.find_or_create_by!(key: "omnipotent") { |c| c.label = "全能"; c.status = "confirmed"; c.include_in_analysis = true }

    @refreshed = Livestream.create!(
      date: Date.new(1998, 3, 5), title: "品牌之夜：薑黃", product_keys: ["turmeric"],
      window_days: 3, total_orders: 100, total_revenue: 50_000, total_buyers: 90, new_buyers: 20,
      reported_orders: 95, reported_revenue: 48_000,
      level_black_count: 10, level_black_amount: 8_000,
      level_gold_count: 20, level_gold_amount: 12_000,
      stats_refreshed_at: Time.current
    )
    @not_refreshed = Livestream.create!(date: Date.new(1998, 4, 5), title: "品牌之夜：全能", product_keys: ["omnipotent"], window_days: 3)
  end

  # ── 權限 ─────────────────────────────────────────────────────────────────

  test "admin can access index and show" do
    sign_in @admin
    get livestreams_path
    assert_response :success
    get livestream_path(@refreshed)
    assert_response :success
  end

  test "staff without page_permissions is redirected away from index" do
    sign_in @staff
    get livestreams_path
    assert_redirected_to root_path
  end

  test "staff with livestreams page_permission can access index and show (permission behavior unchanged by PR3)" do
    PagePermission.create!(role: @staff_role, controller_name: "livestreams")
    sign_in @staff
    get livestreams_path
    assert_response :success
    get livestream_path(@refreshed)
    assert_response :success
  end

  # ── 列表篩選 ─────────────────────────────────────────────────────────────

  test "index filters by year" do
    sign_in @admin
    get livestreams_path(year: 1998, month: 3)
    assert_response :success
    assert_includes @response.body, "薑黃"
    assert_not_includes @response.body, "品牌之夜：全能"
  end

  test "index filters by product_keys via GIN-compatible contains query" do
    sign_in @admin
    get livestreams_path(product: "omnipotent")
    assert_response :success
    assert_includes @response.body, "品牌之夜：全能"
    assert_not_includes @response.body, "品牌之夜：薑黃"
  end

  test "index with no matching filter shows empty state, not an error" do
    sign_in @admin
    get livestreams_path(year: 1999)
    assert_response :success
    assert_includes @response.body, "篩選條件下沒有場次"
  end

  # ── N+1 / query 數 ───────────────────────────────────────────────────────

  test "index issues a constant number of queries regardless of livestream count" do
    sign_in @admin

    count_small = count_queries { get livestreams_path }
    assert_response :success

    8.times { |i| Livestream.create!(date: Date.new(1998, 1, i + 1), product_keys: ["turmeric"]) }

    count_large = count_queries { get livestreams_path }
    assert_response :success

    assert_operator count_large, :<=, count_small + 2,
                    "index 的查詢數不應隨場次筆數線性增加（懷疑 N+1）：small=#{count_small} large=#{count_large}"
  end

  # ── 詳情頁數據 ────────────────────────────────────────────────────────────

  test "show displays 推定檔期 KPI and 歷史登記 side by side, distinctly labeled" do
    sign_in @admin
    get livestream_path(@refreshed)
    assert_response :success
    assert_includes @response.body, "推定檔期"
    assert_includes @response.body, "歷史登記"
    assert_includes @response.body, "50,000" # total_revenue
    assert_includes @response.body, "48,000" # reported_revenue
  end

  test "show 固定顯示推定歸因徽章文案" do
    sign_in @admin
    get livestream_path(@refreshed)
    assert_includes @response.body, "推定歸因：場次日至 D+3，非訂單真實來源"
  end

  test "show marks 現值卡別 not historical" do
    sign_in @admin
    get livestream_path(@refreshed)
    assert_includes @response.body, "現值卡別"
  end

  test "show displays unmatched buyer count and revenue gap" do
    sign_in @admin
    get livestream_path(@refreshed)
    assert_includes @response.body, "未匹配"
    # total_buyers(90) - (10 黑卡 + 20 金卡) = 60
    assert_includes @response.body, "60"
  end

  test "show has a clear empty state when stats were never refreshed, and does not write or refresh stats on load" do
    sign_in @admin
    assert_no_difference "SyncRun.count" do
      get livestream_path(@not_refreshed)
    end
    assert_response :success
    assert_includes @response.body, "尚未執行過統計刷新"
    assert_nil @not_refreshed.reload.stats_refreshed_at
  end

  test "show marks 數據未定版 while still within the attribution window" do
    within_window = Livestream.create!(date: Date.current, window_days: 3, stats_refreshed_at: Time.current,
                                       total_orders: 1, total_revenue: 1, total_buyers: 1, new_buyers: 0)
    sign_in @admin
    get livestream_path(within_window)
    assert_includes @response.body, "數據未定版"
  end

  test "show does not show 未定版 once the window has fully passed" do
    sign_in @admin
    get livestream_path(@refreshed) # 1998-03-05, window_days 3, far past "now"
    assert_not_includes @response.body, "數據未定版"
  end

  test "show renders mobile card markup and desktop table markup" do
    sign_in @admin
    get livestreams_path
    assert_response :success
    assert_includes @response.body, "d-lg-none"
    assert_includes @response.body, "d-none d-lg-block"
  end

  # ── 原有 CRUD 動線保留 ───────────────────────────────────────────────────

  test "new/create/edit/update/destroy still work" do
    sign_in @admin
    get new_livestream_path
    assert_response :success

    assert_difference "Livestream.count", 1 do
      post livestreams_path, params: { livestream: { date: Date.new(2042, 5, 1), notes: "測試備註" } }
    end
    created = Livestream.find_by(date: Date.new(2042, 5, 1))
    assert_redirected_to livestreams_path

    get edit_livestream_path(created)
    assert_response :success

    patch livestream_path(created), params: { livestream: { notes: "改過的備註" } }
    assert_redirected_to livestreams_path
    assert_equal "改過的備註", created.reload.notes

    assert_difference "Livestream.count", -1 do
      delete livestream_path(created)
    end
  end

  # ── 補強：daily breakdown cache key 組成 ────────────────────────────────

  test "daily breakdown cache key changes when date is corrected, even if stats_refreshed_at is unchanged" do
    # test.rb 的 cache_store 是 :null_store（永遠不快取），無法從外部觀察
    # 「是否命中快取」，所以暫時換一個真的 MemoryStore，用呼叫次數當探針：
    # key 若正確隨 date 改變，同一場次改期前後各自重算一次（呼叫 2 次）；
    # 若 key 漏掉 date，改期後仍會命中舊 key、直接沿用改期前算出的舊資料
    # （呼叫仍是 1 次）。
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    call_count = 0
    original_daily_breakdown = LivestreamAttribution.instance_method(:daily_breakdown)
    LivestreamAttribution.define_method(:daily_breakdown) do
      call_count += 1
      original_daily_breakdown.bind(self).call
    end

    begin
      ls = Livestream.create!(date: Date.new(1996, 1, 10), window_days: 3, stats_refreshed_at: Time.current,
                              total_orders: 1, total_revenue: 1, total_buyers: 1, new_buyers: 0)
      sign_in @admin
      get livestream_path(ls)
      assert_response :success

      ls.update_columns(date: Date.new(1996, 1, 11)) # stats_refreshed_at 刻意不變
      get livestream_path(ls)
      assert_response :success

      assert_equal 2, call_count, "date 不同應該產生不同的 cache key，各自重算一次每日拆解"
    ensure
      LivestreamAttribution.define_method(:daily_breakdown, original_daily_breakdown)
      Rails.cache = original_cache
    end
  end

  # ── 補強：show 對不存在的 id 維持正常 404 行為 ──────────────────────────

  test "show for a nonexistent id raises RecordNotFound (Rails' default, unmodified, 404 mapping in production)" do
    sign_in @admin
    # test.rb 設定 show_exceptions = false，例外會直接往外拋而不是被轉成
    # HTTP 回應；這裡驗證的是「沒有被自訂 rescue_from 攔截改變行為」——
    # ApplicationController／此 controller 皆無 rescue_from RecordNotFound，
    # 所以正式環境會沿用 Rails 對 ActiveRecord::RecordNotFound 的預設 404 對應。
    assert_raises(ActiveRecord::RecordNotFound) do
      get livestream_path(id: 999_999_999)
    end
  end

  # ── 補強：product_keys 篩選參數不得造成 SQL injection ───────────────────

  test "product filter param is safely parameterized, not interpolated into SQL" do
    sign_in @admin
    malicious = "turmeric']::varchar[] OR 1=1; DROP TABLE livestreams; --"

    assert_nothing_raised do
      get livestreams_path(product: malicious)
    end
    assert_response :success
    # 惡意字串被當成一般字面值比對，查不到任何場次，資料表也毫髮無傷
    assert_includes @response.body, "篩選條件下沒有場次"
    assert Livestream.table_exists?
  end

  private

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:sql] =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
