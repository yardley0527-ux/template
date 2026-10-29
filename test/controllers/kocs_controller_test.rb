# frozen_string_literal: true

require "test_helper"

class KocsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role  = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    social_role = Role.find_or_create_by!(key: "social") { |r| r.name = "社群部" }
    PagePermission.find_or_create_by!(role: social_role, controller_name: "kocs")

    @admin  = User.create!(email: "koc_admin@test.com", username: "koc_admin", password: "password123", role: admin_role)
    @social = User.create!(email: "koc_social@test.com", username: "koc_social", password: "password123", role: social_role)

    @koc = Koc.create!(ig_username: "koc_delete_test_#{SecureRandom.hex(4)}", source: "手動新增")
  end

  test "admin 能刪除 KOC" do
    sign_in @admin
    assert_difference "Koc.count", -1 do
      delete koc_path(@koc)
    end
    assert_redirected_to kocs_path
  end

  test "social 也能刪除 KOC" do
    sign_in @social
    assert_difference "Koc.count", -1 do
      delete koc_path(@koc)
    end
    assert_redirected_to kocs_path
  end

  test "social 能新增 KOC 並填 Email，跟其他品牌業配名單頁權限一致" do
    sign_in @social
    assert_difference "Koc.count", 1 do
      post kocs_path, params: { koc: { ig_username: "koc_social_new_#{SecureRandom.hex(4)}", email: "social_added@example.com" } }
    end
    assert_equal "social_added@example.com", Koc.last.email
  end

  test "social 能編輯既有 KOC 的 Email" do
    sign_in @social
    patch koc_path(@koc), params: { koc: { email: "updated_by_social@example.com" } }
    assert_equal "updated_by_social@example.com", @koc.reload.email
  end

  test "非 admin 非 social 不能刪除 KOC" do
    other_role = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: other_role, controller_name: "kocs")
    other = User.create!(email: "koc_other@test.com", username: "koc_other", password: "password123", role: other_role)

    sign_in other
    assert_no_difference "Koc.count" do
      delete koc_path(@koc)
    end
    assert_response :forbidden
  end

  # ── 2026-09-16：隱藏功能（跟刪除並存，不刪資料只是預設列表篩掉）──
  test "social 能隱藏 KOC，隱藏後不刪除資料、只是預設列表看不到" do
    sign_in @social
    assert_no_difference "Koc.count" do
      patch toggle_hidden_koc_path(@koc)
    end
    assert @koc.reload.hidden?
    assert_redirected_to kocs_path
  end

  test "admin 也能隱藏 KOC" do
    sign_in @admin
    patch toggle_hidden_koc_path(@koc)
    assert @koc.reload.hidden?
  end

  test "再次呼叫 toggle_hidden 會取消隱藏" do
    sign_in @social
    @koc.update!(hidden: true)

    patch toggle_hidden_koc_path(@koc)

    assert_not @koc.reload.hidden?
  end

  test "非 admin 非 social 不能隱藏 KOC" do
    other_role = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: other_role, controller_name: "kocs")
    other = User.create!(email: "koc_other_hide@test.com", username: "koc_other_hide", password: "password123", role: other_role)

    sign_in other
    patch toggle_hidden_koc_path(@koc)

    assert_response :forbidden
    assert_not @koc.reload.hidden?
  end

  test "index 預設不顯示已隱藏的 KOC，但加上 hidden=1 篩選時只顯示已隱藏的" do
    @koc.update!(hidden: true)
    visible_koc = Koc.create!(ig_username: "koc_visible_#{SecureRandom.hex(4)}", source: "手動新增")
    sign_in @admin

    get kocs_path
    assert_response :success
    assert_includes response.body, visible_koc.ig_username
    assert_not_includes response.body, @koc.ig_username

    get kocs_path(hidden: "1")
    assert_response :success
    assert_includes response.body, @koc.ig_username
    assert_not_includes response.body, visible_koc.ig_username
  end

  test "公關品可以分多次寄出，最近一次日期同步到 KOC，刪除後退回前一次" do
    sign_in @admin
    post gift_shipments_koc_path(@koc), params: { gift_shipment: { shipped_on: "2026-08-21", items: "代謝錠x1" } }
    post gift_shipments_koc_path(@koc), params: { gift_shipment: { shipped_on: "2026-09-30", items: "代謝錠x2", notes: "成效好加寄" } }

    @koc.reload
    assert_equal 2, @koc.gift_shipments.size
    assert_equal Date.new(2026, 9, 30), @koc.pr_gift_shipped_at

    get kocs_path(shipped: "1")
    assert_includes response.body, "第 2 次"
    assert_includes response.body, "成效好加寄"

    delete gift_shipment_koc_path(@koc, shipment_id: @koc.gift_shipments.last.id)
    assert_equal Date.new(2026, 8, 21), @koc.reload.pr_gift_shipped_at
  end

  test "沒填寄出日期不會新增紀錄" do
    sign_in @admin
    assert_no_difference -> { KocGiftShipment.count } do
      post gift_shipments_koc_path(@koc), params: { gift_shipment: { shipped_on: "", items: "代謝錠x1" } }
    end
  end

  test "社群部不能新增公關品寄送紀錄，物流部 crmdata 可以" do
    sign_in @social
    post gift_shipments_koc_path(@koc), params: { gift_shipment: { shipped_on: "2026-08-21" } }
    assert_response :forbidden

    logistics_role = Role.find_or_create_by!(key: "logistics") { |r| r.name = "物流部" }
    PagePermission.find_or_create_by!(role: logistics_role, controller_name: "kocs")
    crmdata = User.create!(email: "koc_crmdata@test.com", username: "crmdata", password: "password123", role: logistics_role)
    sign_in crmdata
    assert_difference -> { KocGiftShipment.count }, 1 do
      post gift_shipments_koc_path(@koc), params: { gift_shipment: { shipped_on: "2026-08-21" } }
    end
  end
end
