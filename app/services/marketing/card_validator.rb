# frozen_string_literal: true

module Marketing
  # 檢查 AI 回來的建議卡：結構、引用的 metric／segment／product／promotion 都要在快照裡，
  # 文字裡出現的數字也要對得回快照，否則整張卡擋下並記原因。
  # 客群人數一律用快照裡程式算的值，不用 AI 寫的。
  class CardValidator
    KINDS = {
      "segment_ops"     => "可確認客群的經營",
      "public_content"  => "公開內容",
      "data_collection" => "補齊身分／興趣資訊的互動設計"
    }.freeze
    CHANNELS = {
      "ig_dm_manual" => "IG 私訊（人工）", "manychat_flow" => "ManyChat Flow", "ig_post" => "IG 貼文",
      "ig_reel" => "Reel", "ig_story" => "限動", "ig_live" => "直播", "line_oa" => "LINE 官方帳號"
    }.freeze
    TEXT_FIELDS = %w[title goal why_now content_theme format success_metric evaluation].freeze
    LIST_FIELDS = %w[pre_checks uncertainties].freeze
    REQUIRED = %w[kind title goal why_now metric_ids content_theme channels success_metric evaluation].freeze
    # 文字裡可自由出現的數字：觀察期天數、24 小時窗口
    FREE_NUMBERS = %w[7 14 24 30].freeze

    def initialize(snapshot)
      @snapshot = snapshot
      @metric_ids = Array(snapshot["metrics"]).map { |m| m["id"] }
      @segments = Array(snapshot["segments"]).index_by { |s| s["id"] }
      @products = Array(snapshot["products"]).map { |p| p["key"] }
      @promotions = Array(snapshot["promotions"]).index_by { |p| p["id"] }
      @numbers = allowed_numbers
    end

    # 回傳 [通過的卡, 被擋的卡（含原因）]
    def call(cards)
      return [[], [{ "reason" => "回應不是建議卡陣列" }]] unless cards.is_a?(Array)

      accepted = []
      rejected = []
      cards.first(8).each do |card|
        errors = errors_for(card)
        if errors.empty?
          accepted << normalize(card)
        else
          rejected << { "title" => card.is_a?(Hash) ? card["title"].to_s[0, 80] : nil, "reasons" => errors }
        end
      end
      [accepted, rejected]
    end

    private

    def errors_for(card)
      return ["格式不是物件"] unless card.is_a?(Hash)

      errs = []
      REQUIRED.each { |k| errs << "缺少 #{k}" if card[k].blank? }
      errs << "kind 不正確：#{card['kind']}" unless KINDS.key?(card["kind"])
      seg = card["segment_id"].presence
      errs << "引用不存在的客群：#{seg}" if seg && !@segments.key?(seg)
      errs << "客群經營建議必須指定客群" if card["kind"] == "segment_ops" && seg.nil?
      bad_metrics = Array(card["metric_ids"]) - @metric_ids - @segments.keys
      errs << "引用不存在的指標：#{bad_metrics.join(', ')}" if bad_metrics.any?
      bad_products = Array(card["product_keys"]) - @products
      errs << "引用不存在的產品：#{bad_products.join(', ')}" if bad_products.any?
      promo = card["promotion_id"]
      errs << "引用不存在的優惠：#{promo}" if promo.present? && !@promotions.key?(promo.to_i)
      bad_channels = Array(card["channels"]) - CHANNELS.keys
      errs << "不支援的管道：#{bad_channels.join(', ')}" if bad_channels.any?
      unknown_numbers = numbers_in(text_of(card)).reject { |n| @numbers.include?(canonical(n)) }
      errs << "文字中的數字對不回資料：#{unknown_numbers.join(', ')}" if unknown_numbers.any?
      errs
    end

    def normalize(card)
      seg = @segments[card["segment_id"].presence]
      card.slice(*TEXT_FIELDS, *LIST_FIELDS, "kind", "metric_ids", "product_keys", "channels")
          .merge("segment_id" => seg&.dig("id"), "segment_count" => seg&.dig("count"),
                 "promotion_id" => card["promotion_id"].presence&.to_i,
                 "pre_checks" => Array(card["pre_checks"]), "uncertainties" => Array(card["uncertainties"]),
                 "product_keys" => Array(card["product_keys"]))
    end

    # 名稱裡的數字（如「PDRN post1」「b群1」）不算；跟英文字母黏在一起的也不算
    def numbers_in(text)
      @names ||= (Array(@snapshot["sources"]).map { |s| s["name"] } + Array(@snapshot["metrics"]).map { |m| m["label"] } +
                  @segments.values.flat_map { |s| [s["label"], s["conditions"]] } + Array(@snapshot["products"]).map { |p| p["label"] })
                 .compact.uniq.sort_by { |n| -n.length }
      stripped = @names.reduce(text) { |t, n| t.gsub(n, " ") }
      stripped.scan(/(?<![A-Za-z0-9.])\d+(?:\.\d+)?(?![A-Za-z0-9])/).uniq
    end

    def text_of(card)
      (TEXT_FIELDS.map { |k| card[k].to_s } + LIST_FIELDS.flat_map { |k| Array(card[k]).map(&:to_s) }).join("\n")
    end

    def allowed_numbers
      values = FREE_NUMBERS.dup
      Array(@snapshot["metrics"]).each { |m| values << m["value"] }
      @segments.each_value do |s|
        values << s["count"]
        values.concat(s["params"].values.grep(Integer))
        values.concat(nested_numbers(s["breakdown"]))
      end
      @promotions.each_value { |p| values.push(p["regular_price"], p["sale_price"], p["discount_pct"]) }
      # 資料日期的月、日（如「訂單資料到 10/27」）
      Array(@snapshot["data_as_of"]&.values).compact.each do |d|
        date = Date.parse(d.to_s) rescue nil
        values.push(date.month, date.day) if date
      end
      values.compact.map { |v| canonical(v.to_s) }.to_set
    end

    def nested_numbers(obj)
      case obj
      when Hash then obj.values.flat_map { |v| nested_numbers(v) }
      when Array then obj.flat_map { |v| nested_numbers(v) }
      when Numeric then [obj]
      else []
      end
    end

    # 12.0 與 12 視為同一個數字
    def canonical(str)
      f = Float(str)
      f == f.round ? f.round.to_s : f.round(1).to_s
    rescue ArgumentError
      str
    end
  end
end
