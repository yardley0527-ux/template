require "test_helper"

class IgReviewsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @item = IgReviewItem.create!(source_key: "a", kind: "risk", severity: "高", title: "孕期建議", event_codes: ["EV-1"], customer_name: "測試客人", as_of: Date.new(2026, 1, 2))
    IgReviewItem.create!(source_key: "b", kind: "method", title: "先問需求", detail: { "原句" => "你最在意什麼" })
  end

  test "guests are redirected" do
    get ig_reviews_path
    assert_response :redirect
  end

  test "admin sees items and can mark contacted" do
    sign_in_admin
    get ig_reviews_path(kind: "risk")
    assert_response :success
    assert_includes response.body, "孕期建議"
    assert_includes response.body, "測試客人"

    patch ig_review_path(@item), params: { status: "contacted", note: "已電話聯絡" }
    assert_redirected_to ig_reviews_path(kind: "risk")
    @item.reload
    assert_equal "contacted", @item.status
    assert_equal "已電話聯絡", @item.note
  end

  test "search filters by customer name" do
    sign_in_admin
    get ig_reviews_path(kind: "risk", q: "不存在的字")
    assert_includes response.body, "沒有符合的項目"
  end

  private

  def sign_in_admin
    role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "igreview@test.com", username: "igreview", password: "password123", role: role)
  end
end
