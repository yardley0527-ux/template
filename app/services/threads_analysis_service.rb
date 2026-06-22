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

    top_posts   = posts.sort_by { |p| -(p.like_count + p.reply_count * 2 + p.repost_count) }.first(30)
    posts_text  = top_posts.map do |p|
      "【#{p.keyword}】@#{p.username}：#{p.text_content.to_s.first(150)}（❤️#{p.like_count} 💬#{p.reply_count} 🔁#{p.repost_count}）#{p.post_url}"
    end.join("\n")

    category_text = category_summary(stats)

    prompt = <<~PROMPT
      以下是今天從 Threads 抓取的保健食品相關貼文，依品牌監控的分類統計：

      #{category_text}

      互動量最高的熱門貼文（含帳號、文字、互動數、連結）：

      #{posts_text}

      你是在跟我們公司同事說話，這份內容是接下來一週的社群企劃參考，需要兩種東西：先讓大家看懂這週 Threads 上發生了什麼，再給社群小編具體可執行的行動建議。盡量點名具體分類/帳號/貼文，不要只講通則。

      請依序輸出以下四個面向：
      1. 本週話題總覽：依分類說明這週的熱度分布與消費者在意什麼，幫團隊建立全貌認知
      2. 可立即互動：這幾篇熱門貼文裡，哪些適合現在就去留言或轉發互動、蹭熱度
      3. 本週內容方向：可以發什麼樣的原創內容（主題、角度、形式）來搭上這些討論
      4. 注意事項：有什麼話題或行銷角度要避免，以免引發負面反應

      格式規定（嚴格遵守）：
      - 第 1 點本週話題總覽列出 5-8 個要點，第 2、3 點各列出 3-5 個要點，第 4 點列出 2-4 個要點
      - 每個要點獨立一行、開頭加「・」、限制在 60 字以內
      - 四個面向之間各留一個空行分隔
      - 不要開場白、不要結尾總結、不要任何標題文字或數字編號、不要 markdown 粗體
      - 直接從第一個要點開始輸出
    PROMPT

    call_claude(prompt, api_key)
  end

  def category_summary(stats)
    stats_by_keyword = stats.index_by { |s| s[:keyword] }

    ThreadsScraperService::KEYWORD_CATEGORIES.filter_map do |category, keywords|
      kw_stats = keywords.filter_map { |kw| stats_by_keyword[kw] }
      next if kw_stats.empty?

      total_count      = kw_stats.sum { |s| s[:count] }
      total_engagement = kw_stats.sum { |s| s[:total_engagement] }
      top              = kw_stats.max_by { |s| s[:total_engagement] }

      "#{category}（#{keywords.join('/')}）：共 #{total_count} 篇、總互動 #{total_engagement}，本週最熱關鍵字是「#{top[:keyword]}」（互動 #{top[:total_engagement]}）"
    end.join("\n")
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
      max_tokens: 2200,
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
