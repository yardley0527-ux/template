require "test_helper"

class LoginThrottleTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store.clear
  end

  def attempt(username, ip: "203.0.113.1")
    post "/users/sign_in",
         params: { user: { username: username, password: "wrong-password" } },
         headers: { "CF-Connecting-IP" => ip }
    response.status
  end

  test "同一帳號第 6 次失敗登入回 429，即使換 IP" do
    5.times { |i| assert_not_equal 429, attempt("Victim", ip: "203.0.113.#{i + 10}") }
    assert_equal 429, attempt("victim", ip: "198.51.100.99")
    assert_equal "60", response.headers["Retry-After"]
  end

  test "同一 IP 第 11 次登入回 429" do
    10.times { |i| assert_not_equal 429, attempt("user#{i}") }
    assert_equal 429, attempt("user_another")
  end

  test "不同 IP、不同帳號互不影響" do
    5.times { attempt("victim") }
    assert_equal 429, attempt("victim", ip: "203.0.113.50")
    assert_not_equal 429, attempt("someone_else", ip: "203.0.113.51")
  end

  test "GET 登入頁不受限流" do
    20.times do
      get "/users/sign_in", headers: { "CF-Connecting-IP" => "203.0.113.1" }
      assert_equal 200, response.status
    end
  end
end
