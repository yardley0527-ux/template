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

  # ── 2026-09-16：確認「所有欄位」都能正確儲存，不是只有前一輪改過
  # local:false的3個checkbox/select/date——文字欄位(email/notes/
  # logistics_notes，用Save按鈕送出，沒有改過local設定)跟follows_official_ig
  # 也一併覆蓋，避免有漏測的欄位。──

  test "social 能編輯既有 KOC 的社群聯絡備註" do
    sign_in @social
    patch koc_path(@koc), params: { koc: { notes: "社群備註測試內容" } }
    assert_equal "社群備註測試內容", @koc.reload.notes
  end

  test "social 不能編輯物流部備註（權限限admin/物流部）" do
    sign_in @social
    patch koc_path(@koc), params: { koc: { logistics_notes: "social不該存進去" } }
    assert_nil @koc.reload.logistics_notes
  end

  test "admin 能編輯物流部備註" do
    sign_in @admin
    patch koc_path(@koc), params: { koc: { logistics_notes: "admin填的物流備註" } }
    assert_equal "admin填的物流備註", @koc.reload.logistics_notes
  end

  test "crmdata（物流部帳號）能編輯物流部備註" do
    logistics_role = Role.find_or_create_by!(key: "logistics") { |r| r.name = "物流部" }
    PagePermission.find_or_create_by!(role: logistics_role, controller_name: "kocs")
    logistics_user = User.create!(email: "koc_logistics@test.com", username: "crmdata", password: "password123", role: logistics_role)

    sign_in logistics_user
    patch koc_path(@koc), params: { koc: { logistics_notes: "物流部自己填的備註" } }
    assert_equal "物流部自己填的備註", @koc.reload.logistics_notes
  end

  test "以 XHR 方式勾選 follows_official_ig 會正確存進資料庫" do
    sign_in @social
    assert_not @koc.follows_official_ig?

    patch koc_path(@koc), params: { koc: { follows_official_ig: "1" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert @koc.reload.follows_official_ig?
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

  # ── 2026-09-16：使用者實際回報「打勾但沒存到」——追查發現 update action
  # 完全沒檢查 @koc.update 的回傳值，驗證失敗時仍然無條件 redirect_back 並
  # 顯示「已更新」成功訊息，導致真正的存檔失敗會被悄悄吃掉、使用者無從
  # 得知。修正為：失敗要回422，前端AJAX才能偵測到並提示使用者。──
  test "update 驗證失敗時回傳422，不能悄悄redirect_back假裝成功" do
    sign_in @social

    patch koc_path(@koc), params: { koc: { ig_username: "" } }

    assert_response :unprocessable_entity
    assert_not_equal "", @koc.reload.ig_username
  end

  # ── 2026-09-16：checkbox/select/date 改成 local:false（AJAX）後，確認
  # 「打勾還是會正確存進資料庫」——local:true/false只影響瀏覽器送出表單的
  # 方式（整頁導航 vs. XHR），不影響PATCH本身的params/路由/controller邏輯，
  # 但實際用XHR請求（含Referer header，模擬瀏覽器remote form送出時的行為）
  # 跑一次，比純理論推論更可靠。
  test "以 XHR 方式勾選 follows_chloe_ig（模擬 local:false 表單送出）會正確存進資料庫" do
    sign_in @social
    assert_not @koc.follows_chloe_ig?

    patch koc_path(@koc), params: { koc: { follows_chloe_ig: "1" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert @koc.reload.follows_chloe_ig?
  end

  test "以 XHR 方式取消勾選 email_sent 會正確存進資料庫" do
    @koc.update!(email_sent: true)
    sign_in @social

    patch koc_path(@koc), params: { koc: { email_sent: "0" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_not @koc.reload.email_sent?
  end

  test "以 XHR 方式改變聯絡狀態下拉選單會正確存進資料庫" do
    sign_in @social

    patch koc_path(@koc), params: { koc: { status: "已接洽" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal "已接洽", @koc.reload.status
  end

  test "以 XHR 方式改變拍影片狀態下拉選單會正確存進資料庫" do
    sign_in @social

    patch koc_path(@koc), params: { koc: { video_shoot_status: "已拍攝" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal "已拍攝", @koc.reload.video_shoot_status
  end

  test "以 XHR 方式填公關品寄出日期會正確存進資料庫（物流欄位限admin/物流部，用admin測）" do
    sign_in @admin

    patch koc_path(@koc), params: { koc: { pr_gift_shipped_at: "2026-09-20" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal Date.new(2026, 9, 20), @koc.reload.pr_gift_shipped_at
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
end
