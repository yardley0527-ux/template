# 規則式團購／業配偵測（關鍵字 + regex 的 MVP，不是 AI）。
# confidence 只用來排序/標示「比較像團購」的貼文，不會拿來隱藏資料——
# 每篇被 IgScraperService 抓到的貼文都會存一筆 GroupBuyDetection，交給人工在
# 「網紅團購商品追蹤」頁面確認或排除，避免用詞比較特殊的合作貼文被規則誤判漏掉。
class GroupBuyDetector
  GROUP_BUY_KEYWORDS = %w[團購 開團 揪團 團購連結 團購價 限時開團 團購中 快閃團].freeze
  SPONSOR_KEYWORDS = [
    "業配", "贊助", "合作邀約", "廠商邀約", "感謝邀約", "廣告合作",
    "paid partnership", "sponsored", "#ad",
  ].freeze
  PURCHASE_KEYWORDS = %w[折扣碼 優惠碼 蝦皮 購買連結 傳送門 私訊 賣場 官方連結 下單 momo 限時優惠].freeze
  HASHTAG_SIGNAL_KEYWORDS = %w[團購 業配 合作 ad sponsored 廣告].freeze
  COLLAB_REGEX = /(?:與|和|跟)\s*([A-Za-z0-9_@.\p{Han}]{2,20})\s*(?:合作|聯名)/

  def self.upsert_for(ig_post)
    new(ig_post).upsert
  end

  def initialize(ig_post)
    @post = ig_post
  end

  def upsert
    detection = GroupBuyDetection.find_or_initialize_by(ig_post: @post)
    result = detect

    if detection.persisted? && detection.status != "待確認"
      # 已經人工確認/排除過，只更新規則判斷本身的欄位，不要動人工填的 status/note/品牌/商品名。
      detection.update!(is_group_buy: result[:is_group_buy], confidence: result[:confidence], matched_keywords: result[:matched_keywords])
    else
      detection.assign_attributes(
        is_group_buy: result[:is_group_buy],
        confidence: result[:confidence],
        matched_keywords: result[:matched_keywords],
        detected_brand: result[:detected_brand],
        detected_product_name: result[:detected_product_name],
      )
      detection.save!
    end

    detection
  end

  def detect
    text = @post.caption.to_s

    group_buy_matches = matches_in(text, GROUP_BUY_KEYWORDS)
    sponsor_matches = matches_in(text, SPONSOR_KEYWORDS)
    purchase_matches = matches_in(text, PURCHASE_KEYWORDS)
    hashtags = @post.hashtags || []
    hashtag_matches = hashtags.select { |h| HASHTAG_SIGNAL_KEYWORDS.any? { |k| h.downcase.include?(k.downcase) } }

    matched_keywords = (group_buy_matches + sponsor_matches + purchase_matches + hashtag_matches).uniq

    confidence = 0
    confidence += group_buy_matches.size * 35
    confidence += sponsor_matches.size * 30
    confidence += purchase_matches.size * 15
    confidence += hashtag_matches.size * 20
    confidence += 10 if (@post.tagged_users || []).any?
    confidence = confidence.clamp(0, 100)

    collab_match = text.match(COLLAB_REGEX)
    mentions = @post.mentions || []
    detected_brand = collab_match&.[](1) ||
      mentions.find { |m| m.to_s.downcase != @post.ig_profile.username.to_s.downcase } ||
      (@post.tagged_users || []).first

    {
      is_group_buy: confidence >= 30,
      confidence: confidence,
      matched_keywords: matched_keywords,
      detected_brand: detected_brand,
      detected_product_name: guess_product_name(text),
    }
  end

  private

  def matches_in(text, keywords)
    lower = text.downcase
    keywords.select { |k| lower.include?(k.downcase) }
  end

  def guess_product_name(caption)
    cleaned = caption.gsub(/#\S+/, "").gsub(/@\S+/, "").strip
    first_line = cleaned.split(/[\n。！]/).first.to_s.strip
    return nil if first_line.blank?

    first_line.length > 40 ? "#{first_line[0, 40]}…" : first_line
  end
end
