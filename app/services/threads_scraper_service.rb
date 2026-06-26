require 'net/http'
require 'json'

class ThreadsScraperService
  API_BASE               = "https://api.apify.com/v2/acts/automation-lab~threads-scraper/run-sync-get-dataset-items"
  API_KEY                = ENV['APIFY_API_KEY']
  MAX_POSTS_PER_CATEGORY = 30

  KEYWORD_CONFIG = {
    "代謝瘦身" => {
      search_seeds:   %w[減肥 水腫],
      local_keywords: %w[代謝 減肥 瘦身 燃脂 體脂 減脂 水腫 胖了 瘦不下來 復胖 易胖 吃太多 變胖]
    },
    "腸道排便" => {
      search_seeds:   %w[便秘 脹氣],
      local_keywords: %w[益生菌 腸道健康 便秘 排便 脹氣 腸胃 肚子脹 消化不好 大不出來]
    },
    "美白抗老" => {
      search_seeds:   %w[美白 膠原蛋白],
      local_keywords: %w[美白 穀胱甘肽 膠原蛋白 NMN 白藜蘆醇 抗老 亮白 暗黃 斑點]
    },
    "私密保養" => {
      search_seeds:   %w[私密 泌尿],
      local_keywords: %w[蔓越莓 私密處 泌尿道 私密保養 搔癢 分泌物]
    },
    "眼睛保健" => {
      search_seeds:   %w[眼睛 乾眼],
      local_keywords: %w[眼睛保健 蝦紅素 花青素 乾眼症 眼睛疲勞 視力]
    },
    "肝臟護肝" => {
      search_seeds:   %w[護肝 薑黃],
      local_keywords: %w[薑黃 護肝 肝臟 肝指數 脂肪肝]
    },
    "魚油心血管" => {
      search_seeds:   %w[魚油 發炎],
      local_keywords: %w[魚油 發炎 omega 心血管 三酸甘油脂 膽固醇]
    },
    "睡眠疲勞" => {
      search_seeds:   %w[失眠 疲勞],
      local_keywords: %w[失眠 疲勞 B群 落髮 髮際線 好累 沒精神 熬夜 睡不好 精神不好]
    },
    "皮膚保養" => {
      search_seeds:   %w[痘痘 敏感肌],
      local_keywords: %w[痘痘 敏感肌 暗沉 面膜 乾燥 泛紅 毛孔 出油 皮膚爛]
    },
    "骨骼保健" => {
      search_seeds:   %w[骨質疏鬆 補鈣],
      local_keywords: %w[骨質疏鬆 鈣 骨密度 關節 骨骼]
    },
  }.freeze

  CATEGORIES         = KEYWORD_CONFIG.keys.freeze
  ALL_LOCAL_KEYWORDS = KEYWORD_CONFIG.values.flat_map { |v| v[:local_keywords] }.uniq.freeze

  EXCLUDE_KEYWORDS = %w[抽獎 業配 團購 折扣碼 私訊我 下單 連結在首頁 政治 選舉 政黨 吵架].freeze

  QUESTION_WORDS = %w[有人 怎麼辦 有推薦嗎 正常嗎 有救嗎 大家都 怎麼改善].freeze

  def self.run(category: nil)
    new.call(category: category)
  end

  def call(category: nil)
    if API_KEY.blank?
      Rails.logger.error("[ThreadsScraperService] APIFY_API_KEY 未設定")
      return false
    end

    today = Date.today
    total_saved = 0

    categories_to_fetch = category.present? ? [category] : CATEGORIES

    categories_to_fetch.each do |cat|
      config = KEYWORD_CONFIG[cat]
      unless config
        Rails.logger.warn("[ThreadsScraperService] 未知分類: #{cat}")
        next
      end
      total_saved += fetch_and_save_category(cat, config, today)
    end

    Rails.logger.info("[ThreadsScraperService] 完成，共儲存 #{total_saved} 則")
    true
  rescue => e
    Rails.logger.error("[ThreadsScraperService] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_and_save_category(category, config, today)
    if ThreadsFetchLog.recently_fetched?(category)
      Rails.logger.info("[ThreadsScraperService] category=#{category} cache hit，跳過")
      return 0
    end

    posts     = fetch_seeds(config[:search_seeds])
    local_kws = config[:local_keywords]
    saved     = 0

    posts.each do |item|
      text = item["text"].to_s

      next unless relevant?(text, local_kws)
      next if excluded?(text)

      like_count  = item["likeCount"].to_i
      reply_count = item["replyCount"].to_i
      next unless reply_count >= 3 && like_count >= 10

      post_id = item["postId"].to_s
      next if post_id.blank?

      matched_kws = local_kws.select { |kw| text.include?(kw) }
      posted_at   = parse_time(item["date"] || item["timestamp"])
      score       = compute_score(text, like_count, reply_count, matched_kws, posted_at)
      username    = item["username"]
      code        = item["code"]

      ThreadsPost.find_or_initialize_by(post_id: post_id).tap do |p|
        p.username           = username
        p.full_name          = item["fullName"].to_s.presence || username
        p.text_content       = text.slice(0, 500)
        p.like_count         = like_count
        p.reply_count        = reply_count
        p.repost_count       = item["repostCount"].to_i
        p.post_url           = item["url"].presence || (code.present? && username.present? ? "https://www.threads.net/@#{username}/post/#{code}" : nil)
        p.keyword            = p.keyword.presence || category
        p.matched_keywords   = ((p.matched_keywords   || []) + matched_kws).uniq
        p.matched_categories = ((p.matched_categories || []) + [category]).uniq
        p.interaction_score  = score
        p.posted_at          = posted_at
        p.fetched_on         = today
        p.save!
        saved += 1
      end
    rescue => e
      Rails.logger.warn("[ThreadsScraperService] skip post: #{e.message}")
    end

    log_fetch(category, config[:search_seeds], saved)
    Rails.logger.info("[ThreadsScraperService] category=#{category} seeds=#{config[:search_seeds].join(',')} raw=#{posts.size} saved=#{saved}")
    saved
  end

  def compute_score(text, like_count, reply_count, matched_kws, posted_at)
    question_bonus  = QUESTION_WORDS.any? { |w| text.include?(w) } ? 20 : 0
    freshness_bonus = (posted_at && posted_at >= 24.hours.ago) ? 10 : 0
    reply_count * 5 + like_count + matched_kws.size * 10 + question_bonus + freshness_bonus
  end

  def fetch_seeds(seeds)
    uri = URI(API_BASE)
    uri.query = URI.encode_www_form(token: API_KEY)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { mode: "search", searchQueries: seeds, maxPosts: MAX_POSTS_PER_CATEGORY }.to_json

    response = http.request(request)
    posts = JSON.parse(response.body)
    posts = [] unless posts.is_a?(Array)

    Rails.logger.info("[ThreadsScraperService] seeds=#{seeds.join(',')} status=#{response.code} count=#{posts.size}")
    posts
  rescue => e
    Rails.logger.warn("[ThreadsScraperService] fetch error seeds=#{seeds.join(',')}: #{e.message}")
    []
  end

  def log_fetch(category, seeds, result_count)
    ThreadsFetchLog.create!(
      category:      category,
      search_queries: seeds,
      fetched_at:    Time.current,
      result_count:  result_count,
      status:        "success"
    )
  rescue => e
    Rails.logger.warn("[ThreadsScraperService] log_fetch failed: #{e.message}")
  end

  def relevant?(text, local_keywords)
    local_keywords.any? { |kw| text.include?(kw) }
  end

  def excluded?(text)
    EXCLUDE_KEYWORDS.any? { |ex| text.include?(ex) }
  end

  def parse_time(raw)
    return nil if raw.blank?
    raw.is_a?(Numeric) ? Time.at(raw) : Time.parse(raw.to_s)
  rescue
    nil
  end
end
