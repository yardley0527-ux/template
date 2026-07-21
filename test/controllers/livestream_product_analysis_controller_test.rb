# frozen_string_literal: true

require "test_helper"

class LivestreamProductAnalysisControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ALL_13_KEYS = %w[omnipotent metabolism glutathione collagen turmeric probiotic whitening
                   fish_oil cleanse_powder astaxanthin intimate_powder mask vitamin_dk_calcium].freeze

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "lpa-admin@test.com", username: "lpa_admin", password: "password123", role: admin_role)

    @staff_role = Role.create!(key: "lpa-staff-#{SecureRandom.hex(4)}", name: "LpaStaff")
    @staff = User.create!(email: "lpa-staff@test.com", username: "lpa_staff", password: "password123", role: @staff_role)

    ALL_13_KEYS.each { |k| CrmProduct.find_or_create_by!(key: k) { |c| c.label = k; c.status = "confirmed"; c.include_in_analysis = true } }

    @ls = Livestream.create!(date: Date.current - 30, product_keys: ["omnipotent"], window_days: 3)
  end

  # ── 權限 ─────────────────────────────────────────────────────────────────

  test "admin can access" do
    sign_in @admin
    get livestream_product_analysis_path
    assert_response :success
  end

  test "staff without permission is redirected away" do
    sign_in @staff
    get livestream_product_analysis_path
    assert_redirected_to root_path
  end

  test "staff with livestream_product_analysis permission can access" do
    PagePermission.create!(role: @staff_role, controller_name: "livestream_product_analysis")
    sign_in @staff
    get livestream_product_analysis_path
    assert_response :success
  end

  # ── 13 個產品切換 ────────────────────────────────────────────────────────

  test "index renders successfully for all 13 crm_products" do
    sign_in @admin
    ALL_13_KEYS.each do |key|
      get livestream_product_analysis_path(product: key)
      assert_response :success, "product=#{key} 應該正常渲染"
      assert_includes @response.body, "推定歸因" # 頂部說明橫幅，有無場次都應該顯示
    end
  end

  test "defaults to the first product option when no product param is given" do
    sign_in @admin
    get livestream_product_analysis_path
    assert_response :success
  end

  test "invalid product param degrades to an empty state, not a crash" do
    sign_in @admin
    get livestream_product_analysis_path(product: "not_a_real_product")
    assert_response :success
    assert_includes @response.body, "目前沒有關聯的直播場次"
  end

  # ── 場次來源：product_keys 篩選（GIN 相容，不得 SQL injection）───────────

  test "product param is safely parameterized against product_keys, not vulnerable to injection" do
    sign_in @admin
    malicious = "omnipotent']::varchar[] OR 1=1; DROP TABLE livestreams; --"
    assert_nothing_raised { get livestream_product_analysis_path(product: malicious) }
    assert_response :success
    assert Livestream.table_exists?
  end

  # ── 益生菌特殊模組 ───────────────────────────────────────────────────────

  test "probiotic module renders SKU breakdown and action list only for probiotic" do
    Livestream.create!(date: Date.current - 10, product_keys: ["probiotic"], window_days: 3)
    sign_in @admin

    get livestream_product_analysis_path(product: "probiotic")
    assert_response :success
    assert_includes @response.body, "益生菌 SKU 明細"
    assert_includes @response.body, "行動清單"

    get livestream_product_analysis_path(product: "turmeric")
    assert_not_includes @response.body, "益生菌 SKU 明細"
  end

  test "export_action returns a CSV" do
    Livestream.create!(date: Date.current - 10, product_keys: ["probiotic"], window_days: 3)
    sign_in @admin
    get export_action_livestream_product_analysis_path(product: "probiotic")
    assert_response :success
    assert_equal "text/csv; charset=utf-8", @response.media_type + "; charset=" + @response.charset
  end

  # ── 全能交叉推薦與 IG config ─────────────────────────────────────────────

  test "omnipotent module renders cross-sell and IG discount list, other products do not" do
    sign_in @admin

    get livestream_product_analysis_path(product: "omnipotent")
    assert_response :success
    assert_includes @response.body, "美白 交叉推薦"
    assert_includes @response.body, "IG 折扣碼使用名單"
    assert_includes @response.body, IgDiscountCohortLookup.source

    get livestream_product_analysis_path(product: "turmeric")
    assert_not_includes @response.body, "IG 折扣碼使用名單"
  end

  test "IG discount config yaml loads all 29 entries with metadata" do
    assert_equal 29, IgDiscountCohortLookup.entries.size
    assert_equal Date.new(2026, 10, 8), IgDiscountCohortLookup.review_date
    assert IgDiscountCohortLookup.purpose.present?
  end

  # ── CSV 匯出 ─────────────────────────────────────────────────────────────

  test "export_missing and export_event return CSV" do
    sign_in @admin
    get export_missing_livestream_product_analysis_path(product: "omnipotent")
    assert_response :success
    assert_match(/text\/csv/, @response.media_type)

    get export_event_livestream_product_analysis_path(product: "omnipotent")
    assert_response :success
    assert_match(/text\/csv/, @response.media_type)
  end

  # ── query 數（非嚴格 N+1，但避免明顯爆炸）─────────────────────────────────

  test "index query count does not explode as event count grows" do
    sign_in @admin
    get livestream_product_analysis_path(product: "omnipotent")
    small = count_queries { get livestream_product_analysis_path(product: "omnipotent") }

    5.times { |i| Livestream.create!(date: Date.current - (40 + i), product_keys: ["omnipotent"], window_days: 3) }

    large = count_queries { get livestream_product_analysis_path(product: "omnipotent") }
    # 每場需要獨立算歸因，允許隨場次數成長，但不應該是失控的乘法級增長
    assert_operator large, :<, small * 8, "查詢數增長幅度過大：small=#{small} large=#{large}"
  end

  private

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:sql] =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
