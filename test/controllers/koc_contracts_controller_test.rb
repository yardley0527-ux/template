# frozen_string_literal: true

require "test_helper"

class KocContractsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role   = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    finance_role = Role.find_or_create_by!(key: "finance") { |r| r.name = "財務部" }
    social_role  = Role.find_or_create_by!(key: "social") { |r| r.name = "社群部" }
    PagePermission.find_or_create_by!(role: finance_role, controller_name: "koc_contracts")
    PagePermission.find_or_create_by!(role: social_role, controller_name: "koc_contracts")

    @admin   = User.create!(email: "kc_admin@test.com", username: "kc_admin", password: "password123", role: admin_role)
    @finance = User.create!(email: "kc_finance@test.com", username: "kc_finance", password: "password123", role: finance_role)
    @social  = User.create!(email: "kc_social@test.com", username: "kc_social", password: "password123", role: social_role)

    @koc = Koc.create!(ig_username: "koc_contract_test_#{SecureRandom.hex(4)}", source: "手動新增", status: "合作中")
  end

  test "finance 能看到合約狀態頁" do
    sign_in @finance
    get koc_contracts_path
    assert_response :success
    assert_select "a", text: "@#{@koc.ig_username}"
  end

  test "finance 能更新合約日期" do
    sign_in @finance
    patch koc_contract_path(@koc), params: { koc: { contract_sent_at: "2026-09-22" } }
    assert_redirected_to koc_contracts_path
    assert_equal Date.parse("2026-09-22"), @koc.reload.contract_sent_at
  end

  test "finance 不能更新影片上架時間與廣告區間" do
    sign_in @finance
    patch koc_contract_path(@koc), params: { koc: { video_posted_at: "2026-09-20", ad_start_at: "2026-09-21", ad_end_at: "2026-09-28" } }
    assert_redirected_to koc_contracts_path
    @koc.reload
    assert_nil @koc.video_posted_at
    assert_nil @koc.ad_start_at
    assert_nil @koc.ad_end_at
  end

  test "social 能看到合約狀態頁" do
    sign_in @social
    get koc_contracts_path
    assert_response :success
    assert_select "a", text: "@#{@koc.ig_username}"
  end

  test "social 能更新影片上架時間與廣告區間" do
    sign_in @social
    patch koc_contract_path(@koc), params: { koc: { video_posted_at: "2026-09-20", ad_start_at: "2026-09-21", ad_end_at: "2026-09-28" } }
    assert_redirected_to koc_contracts_path
    @koc.reload
    assert_equal Date.parse("2026-09-20"), @koc.video_posted_at
    assert_equal Date.parse("2026-09-21"), @koc.ad_start_at
    assert_equal Date.parse("2026-09-28"), @koc.ad_end_at
  end

  test "social 不能更新合約日期" do
    sign_in @social
    patch koc_contract_path(@koc), params: { koc: { contract_sent_at: "2026-09-22" } }
    assert_redirected_to koc_contracts_path
    assert_nil @koc.reload.contract_sent_at
  end

  test "沒有權限的帳號不能進合約狀態頁" do
    crm_role = Role.find_or_create_by!(key: "crm") { |r| r.name = "CRM" }
    crm_user = User.create!(email: "kc_crm@test.com", username: "kc_crm", password: "password123", role: crm_role)
    sign_in crm_user
    get koc_contracts_path
    assert_redirected_to root_path
  end

  test "只列出合作中的 KOC" do
    other = Koc.create!(ig_username: "koc_contract_other_#{SecureRandom.hex(4)}", source: "手動新增", status: "已接洽")
    sign_in @finance
    get koc_contracts_path
    assert_select "a", text: "@#{@koc.ig_username}"
    assert_select "a", text: "@#{other.ig_username}", count: 0
  end
end
