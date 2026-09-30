# frozen_string_literal: true

require "test_helper"

class PrGiftsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    crm_role   = Role.find_or_create_by!(key: "crm") { |r| r.name = "客服部" }
    PagePermission.find_or_create_by!(role: crm_role, controller_name: "customers")
    PagePermission.find_or_create_by!(role: crm_role, controller_name: "pr_gifts")

    @owner = User.create!(email: "pg_owner@test.com", username: "pg_owner", password: "password123", role: admin_role)
    @staff = User.create!(email: "pg_staff@test.com", username: "pg_staff", password: "password123", role: crm_role)

    @customer = ShoplineCustomer.create!(email: "pr-gift@example.com")
  end

  def valid_params(overrides = {})
    { pr_gift: { product_name: "魚油", quantity: "1", unit: "瓶", given_on: "2026-09-30", note: "" }.merge(overrides) }
  end

  test "owner 可以新增公關品，記錄日期、數量、單位與填寫人" do
    sign_in @owner
    assert_difference -> { @customer.pr_gifts.count }, 1 do
      post customer_pr_gifts_path(@customer), params: valid_params(quantity: "2", note: "試用")
    end
    assert_redirected_to customer_path(@customer, anchor: "pr-gifts")

    gift = @customer.pr_gifts.last
    assert_equal "魚油", gift.product_name
    assert_equal 2, gift.quantity
    assert_equal "瓶", gift.unit
    assert_equal Date.new(2026, 9, 30), gift.given_on
    assert_equal "試用", gift.note
    assert_equal "pg_owner", gift.created_by
  end

  test "日期留空會自動存今天" do
    sign_in @owner
    post customer_pr_gifts_path(@customer), params: valid_params(given_on: "")
    assert_equal Date.current, @customer.pr_gifts.last.given_on
  end

  test "同一位客人可以送多次，清單最新的在最上面" do
    sign_in @owner
    post customer_pr_gifts_path(@customer), params: valid_params(given_on: "2026-08-12", product_name: "薑黃")
    post customer_pr_gifts_path(@customer), params: valid_params(given_on: "2026-09-30")
    assert_equal %w[魚油 薑黃], @customer.pr_gifts.recent_first.map(&:product_name)
  end

  test "產品選「其他」時使用自己輸入的名稱" do
    sign_in @owner
    post customer_pr_gifts_path(@customer),
         params: valid_params(product_name: PrGiftsController::OTHER_PRODUCT, product_other: " 美容儀 ")
    assert_equal "美容儀", @customer.pr_gifts.last.product_name
  end

  test "選「其他」卻沒填名稱不會存，也不會出現 __other__" do
    sign_in @owner
    assert_no_difference -> { PrGift.count } do
      post customer_pr_gifts_path(@customer),
           params: valid_params(product_name: PrGiftsController::OTHER_PRODUCT, product_other: "")
    end
    assert_match(/沒有存到/, flash[:alert])
  end

  test "數量或單位不合法不會存" do
    sign_in @owner
    assert_no_difference -> { PrGift.count } do
      post customer_pr_gifts_path(@customer), params: valid_params(quantity: "0")
      post customer_pr_gifts_path(@customer), params: valid_params(quantity: "-3")
      post customer_pr_gifts_path(@customer), params: valid_params(unit: "箱")
    end
  end

  test "owner 可以修改公關品" do
    gift = @customer.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @owner
    patch customer_pr_gift_path(@customer, gift), params: valid_params(product_name: "膠原蛋白", quantity: "3", unit: "盒")
    gift.reload
    assert_equal ["膠原蛋白", 3, "盒"], [gift.product_name, gift.quantity, gift.unit]
  end

  test "owner 可以刪除公關品" do
    gift = @customer.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @owner
    assert_difference -> { PrGift.count }, -1 do
      delete customer_pr_gift_path(@customer, gift)
    end
  end

  test "不能改到別位客人的公關品" do
    other = ShoplineCustomer.create!(email: "someone-else@example.com")
    gift  = other.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @owner
    assert_no_difference -> { PrGift.count } do
      # test 環境會直接丟出例外，正式站這裡是 404
      assert_raises(ActiveRecord::RecordNotFound) { delete customer_pr_gift_path(@customer, gift) }
    end
  end

  test "非 owner（即使有頁面權限）新增、修改、刪除都會被擋" do
    gift = @customer.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @staff

    assert_no_difference -> { PrGift.count } do
      post customer_pr_gifts_path(@customer), params: valid_params
      delete customer_pr_gift_path(@customer, gift)
    end
    patch customer_pr_gift_path(@customer, gift), params: valid_params(quantity: "9")
    assert_equal 1, gift.reload.quantity
  end

  test "未登入不能新增" do
    assert_no_difference -> { PrGift.count } do
      post customer_pr_gifts_path(@customer), params: valid_params
    end
    assert_redirected_to new_user_session_path
  end

  test "客戶頁：owner 看得到清單與新增表單" do
    @customer.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @owner
    get customer_path(@customer)
    assert_response :success
    assert_select "#pr-gifts", text: /魚油 ×1瓶/
    assert_select "#pr-gifts button.btn.btn-primary[data-target='#new-pr-gift-modal']", text: /新增公關品/
    assert_select "#new-pr-gift-modal.modal form.pr-gift-form"
    assert_select "#edit-pr-gift-modal-#{@customer.pr_gifts.first.id}.modal form.pr-gift-form"
  end

  test "客戶頁：非 owner 只看得到清單，沒有任何表單或刪除鈕" do
    @customer.pr_gifts.create!(product_name: "魚油", quantity: 1, unit: "瓶", given_on: "2026-09-30")
    sign_in @staff
    get customer_path(@customer)
    assert_response :success
    assert_select "#pr-gifts", text: /魚油 ×1瓶/
    assert_select "form.pr-gift-form", count: 0
    assert_select ".modal[id*='pr-gift']", count: 0
    assert_select "#pr-gifts button[data-toggle=modal]", count: 0
    assert_select "#pr-gifts a[data-method=delete]", count: 0
  end
end
