require 'net/http'
require 'json'

class ThreadsAnalysisService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  MODEL          = "claude-sonnet-4-6"

  def self.run(date = Date.today)
    new(date).call
  end

  def initialize(date)
    @date = date
  end

  def call
    posts = ThreadsPost.where(fetched_on: @date)
    return false if posts.empty?

    stats      = compute_stats(posts)
    ai_summary = generate_ai_summary(posts, stats)

    analysis = ThreadsAnalysis.find_or_initialize_by(fetched_on: @date)
    analysis.stats_json = stats
    analysis.ai_summary = ai_summary
    analysis.save!
    true
  rescue => e
    Rails.logger.error("[ThreadsAnalysisService] #{e.class}: #{e.message}")
    false
  end

  private

  def compute_stats(posts)
    posts.group_by(&:keyword).map do |keyword, kw_posts|
      total_likes    = kw_posts.sum(&:like_count)
      total_replies  = kw_posts.sum(&:reply_count)
      total_reposts  = kw_posts.sum(&:repost_count)
      n              = kw_posts.size.to_f
      engagement     = kw_posts.sum { |p| p.like_count + p.reply_count * 2 + p.repost_count }
      top            = kw_posts.max_by { |p| p.like_count + p.reply_count * 2 + p.repost_count }

      {
        keyword:          keyword,
        count:            kw_posts.size,
        avg_likes:        (total_likes / n).round(1),
        avg_replies:      (total_replies / n).round(1),
        avg_reposts:      (total_reposts / n).round(1),
        total_engagement: engagement,
        top_post: top ? {
          text:  top.text_content.to_s.first(120),
          likes: top.like_count,
          url:   top.post_url
        } : nil
      }
    end.sort_by { |s| -s[:total_engagement] }
  end

  def generate_ai_summary(posts, stats)
    api_key = ENV['ANTHROPIC_API_KEY'].to_s.strip
    if api_key.blank?
      Rails.logger.warn("[ThreadsAnalysisService] ANTHROPIC_API_KEY 未設定，跳過 AI 分析")
      return "（未設定 ANTHROPIC_API_KEY，跳過 AI 分析）"
    end

    top_posts   = posts.sort_by { |p| -(p.like_count + p.reply_count * 2 + p.repost_count) }.first(20)
    posts_text  = top_posts.map do |p|
      "【#{p.keyword}】@#{p.username}：#{p.text_content.to_s.first(150)}（❤️#{p.like_count} 💬#{p.reply_count} 🔁#{p.repost_count}）#{p.post_url}"
    end.join("\n")

    kw_summary = stats.map { |s| "#{s[:keyword]}（#{s[:count]} 則，互動 #{s[:total_engagement]}）" }.join("、")

    prompt = <<~PROMPT
      以下是今天從 Threads 抓取的保健食品相關貼文（關鍵字分布：#{kw_summary}）：

      #{posts_text}

      你是在跟我們公司的社群小編說話，目的是提升品牌在 Threads 上的能見度。請用繁體中文給出具體可執行的行動建議，盡量點名具體帳號/貼文或話題角度，不要只講通則。

      回答以下三個面向：
      1. 這幾篇熱門貼文裡，有哪些適合現在就去留言或轉發互動、蹭熱度
      2. 這週可以發什麼樣的原創內容（主題、角度、形式）來搭上這些討論
      3. 有什麼話題或行銷角度要避免，以免引發負面反應

      格式規定（嚴格遵守）：
      - 每個面向獨立列出 2-3 個要點，每個要點獨立一行、開頭加「・」、限制在 50 字以內
      - 三個面向之間留一個空行分隔
      - 不要開場白、不要結尾總結、不要任何標題文字或數字編號、不要 markdown 粗體
      - 直接從第一個要點開始輸出
    PROMPT

    call_claude(prompt, api_key)
  end

  def call_claude(prompt, api_key)
    uri  = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 60

    req = Net::HTTP::Post.new(uri)
    req["x-api-key"]         = api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = {
      model:      MODEL,
      max_tokens: 1200,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(req)
    body     = JSON.parse(response.body)
    body.dig("content", 0, "text").presence || "（AI 回應解析失敗）"
  rescue => e
    Rails.logger.warn("[ThreadsAnalysisService] Claude API error: #{e.message}")
    "（AI 分析暫時無法使用：#{e.message}）"
  end
end
