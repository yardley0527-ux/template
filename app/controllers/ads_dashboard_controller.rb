class AdsDashboardController < ApplicationController
  def index
    json_path = Rails.root.join('data', 'ads_data.json')
    @ads_data = File.exist?(json_path) ? JSON.parse(File.read(json_path)) : default_data
    @campaigns          = @ads_data['campaigns'] || []
    @active_campaigns   = @campaigns.select { |c| c['status'] == 'ACTIVE' }
    @archived_campaigns = @campaigns.reject { |c| c['status'] == 'ACTIVE' }

    with_data = @active_campaigns.map { |c| [c, latest_day(c)] }.select { |_, d| d }
    totals    = with_data.map(&:last)

    @total_spend       = totals.sum { |d| d['spend'].to_f }
    @total_budget      = @active_campaigns.sum { |c| c['daily_budget'].to_f }
    @total_impressions = totals.sum { |d| d['impressions'].to_i }
    @avg_ctr           = avg(totals.map { |d| d['ctr'].to_f }.select(&:positive?))
    @avg_cpm           = avg(totals.map { |d| d['cpm'].to_f }.select(&:positive?))
    @suggestions       = build_suggestions(@active_campaigns)
  end

  private

  def latest_day(campaign)
    (campaign['daily_data'] || []).max_by { |d| d['date'] }
  end

  def prev_day(campaign)
    sorted = (campaign['daily_data'] || []).sort_by { |d| d['date'] }
    sorted.length >= 2 ? sorted[-2] : nil
  end

  def avg(arr)
    arr.empty? ? nil : arr.sum / arr.size.to_f
  end

  def build_suggestions(campaigns)
    suggestions = []
    campaigns.each do |c|
      l = latest_day(c)
      p = prev_day(c)

      unless l
        suggestions << { type: 'info', icon: '⏳', title: "#{c['name']}｜等待數據",
                         desc: "廣告剛開始，24–48 小時後才有可分析的數據量。" }
        next
      end

      ctr = l['ctr'].to_f
      cpm = l['cpm'].to_f
      spend_rate = l['spend'].to_f / c['daily_budget'].to_f * 100

      if ctr >= 4
        suggestions << { type: 'good', icon: '✅', title: "#{c['name']}｜CTR 優秀（#{ctr}%）",
                         desc: "台灣廣告平均 CTR 約 1–2%，目前 #{ctr}% 遠超平均，素材與受眾高度共鳴，不建議更換素材。" }
      elsif ctr >= 1.5
        suggestions << { type: 'warn', icon: '🔶', title: "#{c['name']}｜CTR 普通（#{ctr}%）",
                         desc: "素材吸引力尚可，可嘗試 A/B 測試不同開頭。",
                         action: "建議：A/B 測試不同開頭畫面或文案" }
      elsif ctr > 0
        suggestions << { type: 'bad', icon: '❌', title: "#{c['name']}｜CTR 偏低（#{ctr}%）",
                         desc: "素材與受眾共鳴不足，建議更換素材或調整受眾。",
                         action: "建議：立即更換素材或調整受眾設定" }
      end

      if cpm.positive? && cpm <= 160
        suggestions << { type: 'good', icon: '💰', title: "#{c['name']}｜CPM 良好（NT$#{cpm.to_i}）",
                         desc: "CPM 偏低，Meta 演算法對素材評分高，投放成本控制在優良範圍。" }
      elsif cpm > 250
        suggestions << { type: 'warn', icon: '⚠️', title: "#{c['name']}｜CPM 偏高（NT$#{cpm.to_i}）",
                         desc: "受眾競爭激烈或素材品質分偏低。",
                         action: "建議：測試新素材，或稍微放寬受眾範圍" }
      end

      v3s  = l['video_3s'].to_f
      v100 = l['video_100'].to_f
      if v3s > 0 && v100 > 0
        completion = v100 / v3s * 100
        if completion < 5
          suggestions << { type: 'warn', icon: '🎬',
                           title: "#{c['name']}｜影片看完率低（#{completion.round(1)}%）",
                           desc: "觀眾在開頭後大量流失，影片可能過長或中段吸引力不足。",
                           action: "建議：剪 15–30 秒精華版做 A/B 測試" }
        end
      end

      if spend_rate < 60
        suggestions << { type: 'warn', icon: '📊',
                         title: "#{c['name']}｜預算消耗不足（#{spend_rate.round(0).to_i}%）",
                         desc: "日預算 NT$#{c['daily_budget'].to_i}，實際花費 NT$#{l['spend'].to_i}。可能在學習期或受眾過窄。",
                         action: "建議：觀察 3–5 天後，若持續低消則放寬受眾" }
      end

      if p && l['cpm'].to_f < p['cpm'].to_f
        drop = ((p['cpm'].to_f - l['cpm'].to_f) / p['cpm'].to_f * 100).round(0).to_i
        suggestions << { type: 'good', icon: '📉',
                         title: "#{c['name']}｜CPM 持續下降（-#{drop}%）",
                         desc: "NT$#{p['cpm'].to_i} → NT$#{l['cpm'].to_i}，演算法學習成效好，成本越來越低。" }
      end
    end
    suggestions
  end

  def default_data
    { 'campaigns' => [], 'last_updated' => nil, 'product' => 'BC葉全能膠囊', 'company' => '苼莛國際生技' }
  end
end
