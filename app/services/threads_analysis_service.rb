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
      "【#{p.keyword}】@#{p.username}：#{p.text_content.to_s.first(150)}（❤️#{p.like_count} 💬#{p.reply_count} 🔁#{p.repost_count}）"
    end.join("\n")

    kw_summary = stats.map { |s| "#{s[:keyword]}（#{s[:count]} 則，互動 #{s[:total_engagement]}）" }.join("、")

    prompt = <<~PROMPT
      以下是今天從 Threads 抓取的保健食品相關貼文（關鍵字分布：#{kw_summary}）：

      #{posts_text}

      請用繁體中文做簡短分析，回答以下三個面向（每段 2-3 句，不加標題編號）：
      1. 本次最熱門的話題或討論方向
      2. 消費者關注的痛點或需求
      3. 值得品牌注意的訊號或機會
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
      max_tokens: 600,
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
