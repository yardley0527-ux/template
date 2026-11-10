# frozen_string_literal: true

require "test_helper"

class MaliciousReturnsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "admin-mr@test.com", username: "admin_mr", password: "password123", role: admin_role)
  end

  test "empty state before the first sync" do
    get malicious_returns_path
    assert_response :success
    assert_includes @response.body, "還沒有同步過"
  end

  test "lists each 惡意退貨 row with its customer and blacklist status" do
    bad = ShoplineCustomer.create!(email: "bad@example.com", full_name: "壞客人")
    MaliciousReturnSync.call(rows: [
      ["是", "#20251009151457201", "TH1", Date.new(2025, 10, 13), "壞客人", "bad@example.com", nil, "惡意退貨"],
      ["否", "#20260926154040284", "FR1", Date.new(2026, 9, 26), "還沒匯入", nil, nil, "惡意退貨"]
    ])

    get malicious_returns_path
    assert_response :success
    assert_includes @response.body, customer_path(bad)
    assert_includes @response.body, "自動加入"
    assert_includes @response.body, "#20260926154040284"
    assert_includes @response.body, "對不到（訂單還沒匯入？）"
  end

  test "sync button runs the sync and reports the result" do
    original = MaliciousReturnSync.method(:call)
    MaliciousReturnSync.define_singleton_method(:call) { |**| { rows: 3, added: ["甲"], unmatched: [] } }
    begin
      post sync_malicious_returns_path
    ensure
      MaliciousReturnSync.define_singleton_method(:call, original)
    end
    assert_redirected_to malicious_returns_path
    assert_equal "同步完成：共 3 筆惡意退貨，新加入黑名單 1 人", flash[:notice]
  end
end
