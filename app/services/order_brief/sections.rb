# frozen_string_literal: true

module OrderBrief
  # 照使用者每天看的訂單簡報格式排版（10/22 那份是範本）：
  # 總覽、其他舊客是純文字；PDRN／全能、很久沒回來是寬表格，交給 TableImage 畫成圖。
  class Sections
    def initialize(report)
      @r = report
    end

    def overview_text
      s = @r.summary
      lines = ["#{md(@r.day)} 全天共 #{s[:people]} 人下單、#{s[:orders]} 張單，營收 #{money(s[:revenue])}",
               "新客 #{s[:new_people]} 人、#{s[:new_orders]} 張單，營收 #{money(s[:new_revenue])}，占 #{s[:new_share]}%",
               "舊客 #{s[:old_people]} 人、#{s[:old_orders]} 張單，營收 #{money(s[:old_revenue])}",
               "", "依卡別分："]
      @r.level_stats.each do |l|
        extra = l[:level] == "一般會員" ? "（含新客 #{l[:new_people]} 人）" : ""
        lines << "#{l[:level]} #{l[:people]} 人#{extra}#{l[:people].positive? ? "，#{money(l[:amount])}" : ''}"
      end
      lines += ["", "依產品分："]
      @r.product_stats.each do |p|
        line = "#{p[:series]} #{p[:people]} 人，付費 #{p[:paid]} 瓶"
        line += "，另送 #{p[:gift]} 瓶" if p[:gift].positive?
        line += p[:pre] == p[:paid] ? "（全部是預購）" : "（預購 #{p[:pre]} 瓶）" if p[:pre].positive?
        lines << line
      end
      lines.join("\n")
    end

    # 依簡報順序排好的段落：[:text, 文字] 或 [:image, 名稱, 標題, blocks]
    # 總覽 → PDRN 表 → 全能表 → 其他舊客 → 很久沒回來表
    def parts
      images = image_sections
      long = images.pop if @r.long_gap.any?
      list = [[:text, "📦 #{md(@r.day)} 訂單簡報\n\n#{overview_text}"]]
      images.each_with_index { |(title, blocks), i| list << [:image, "focus#{i}", title, blocks] }
      list << [:text, others_text] if others_text
      list << [:image, "long_gap", *long] if long
      list
    end

    # [[標題, blocks], ...]，每段一張圖；沒人買的主力產品不出圖
    def image_sections
      list = Report::FOCUS.filter_map do |series|
        f = @r.focus(series)
        next if f[:buyers].zero?

        ["#{series}（#{f[:buyers]} 人：回購 #{f[:repeat].size}、舊客第一次買 #{f[:first].size}、新客 #{f[:fresh].size}）", focus_blocks(series, f)]
      end
      long = @r.long_gap
      if long.any?
        list << ["很久沒回來買的（≥#{Report::LONG_GAP} 天）（#{long.size} 人次）", [
          [:heading, "很久沒回來買的（≥#{Report::LONG_GAP} 天）（#{long.size} 人次）", "隔幾天＝距離任何品項的上一單"],
          [:table, %w[下單日 客人 卡別 這次買 整單 上次消費 隔幾天 上次買什麼 以前買過],
           long.map { |e| [md(@r.day), e[:name], e[:level], e[:today], money(e[:amount]), md(e[:last_date]), "#{e[:gap]} 天", e[:last_items], "#{e[:times]} 次"] }, [6]]
        ]]
      end
      list
    end

    def others_text
      old = @r.other_old
      fresh = @r.other_new
      return nil if old.empty? && fresh.empty?

      lines = ["其他舊客（#{old.size} 人，沒買 #{Report::FOCUS.join(' 和')}）", ""]
      old.each do |e|
        low = e[:low_amount] ? "（實付很低，大概是購物金折抵）" : ""
        same = e[:same_item_date] ? "上次買同品項 #{md(e[:same_item_date])}" : "第一次買這個品項"
        lines << "- #{e[:name]}（#{e[:level]}）：#{e[:today]}，#{money(e[:amount])}#{low}，#{e[:gap]} 天沒來（上次 #{md(e[:last_date])} #{e[:last_items]}），#{same}"
      end
      lines += ["", "其他新客（#{fresh.size} 人）：" + fresh.map { |e| "#{e[:name]}（#{e[:today]}，#{money(e[:amount])}）" }.join("、")] if fresh.any?
      lines.join("\n")
    end

    private

    def focus_blocks(series, f)
      blocks = [[:heading, "#{series}（#{f[:buyers]} 人：回購 #{f[:repeat].size}、舊客第一次買 #{f[:first].size}、新客 #{f[:fresh].size}）", nil]]
      if f[:repeat].any?
        last_col = series == "PDRN" ? "備註" : "最近一次消費"
        blocks << [:heading, "回購 #{series}（#{f[:repeat].size} 人）", "依「多久沒回來」排序"]
        blocks << [:table, ["客人", "卡別", "今天買", "整單", "上次買 #{series}", "隔幾天", last_col],
                   f[:repeat].map { |e| [e[:name], e[:level], e[:today], money(e[:amount]), "#{md(e[:last_date])}（#{e[:last_items]}）", "#{e[:gap]} 天", e[:note]] }, [5]]
      end
      if f[:first].any?
        blocks << [:heading, "舊客第一次買 #{series}（#{f[:first].size} 人）", "依「多久沒來」排序"]
        blocks << [:table, %w[客人 卡別 今天買 整單 上次消費 隔幾天 上次買什麼],
                   f[:first].map { |e| [e[:name], e[:level], e[:today], money(e[:amount]), md(e[:last_date]), "#{e[:gap]} 天", e[:last_items]] }, [5]]
      end
      if f[:fresh].any?
        blocks << [:text, "新客買 #{series}（#{f[:fresh].size} 人）：" + f[:fresh].map { |e| "#{e[:name]}（#{e[:today]}，#{money(e[:amount])}）" }.join("、")]
      end
      blocks
    end

    def md(date) = @r.md(date)
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
