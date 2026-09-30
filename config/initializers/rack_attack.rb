# 登入防暴力破解：同一 IP 或同一帳號短時間內失敗太多次就回 429
class Rack::Attack
  LOGIN_PATH = "/users/sign_in".freeze

  # 站在 Cloudflare → Render 後面，request.ip 會是代理的 IP，
  # 用它限流會讓所有人共用同一個額度，所以優先讀 Cloudflare 帶的真實 IP
  def self.client_ip(req)
    req.get_header("HTTP_CF_CONNECTING_IP").presence || req.ip
  end

  def self.login_attempt?(req)
    req.post? && req.path == LOGIN_PATH
  end

  # 用 Rails.cache（同一台機器的 puma worker 共用）；測試環境用記憶體避免污染
  Rack::Attack.cache.store = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  throttle("logins/ip", limit: 10, period: 1.minute) do |req|
    client_ip(req) if login_attempt?(req)
  end

  # 換 IP 攻同一個帳號也擋得住
  throttle("logins/username", limit: 5, period: 1.minute) do |req|
    if login_attempt?(req)
      user = req.params["user"]
      user["username"].to_s.strip.downcase.presence if user.is_a?(Hash)
    end
  end

  self.throttled_responder = lambda do |req|
    retry_after = (req.env["rack.attack.match_data"] || {})[:period].to_i
    [
      429,
      { "Content-Type" => "text/plain; charset=utf-8", "Retry-After" => retry_after.to_s },
      ["登入嘗試次數過多，請稍後再試。\n"]
    ]
  end
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn("[rack-attack] throttled #{req.env['rack.attack.matched']} ip=#{Rack::Attack.client_ip(req)}")
end
