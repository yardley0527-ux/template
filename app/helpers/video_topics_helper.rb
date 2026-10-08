module VideoTopicsHelper
  CIRCLED_NUMBERS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  DEFAULT_SHOT_HEADERS = %w[鏡頭與動作 講解方向 圖片／字幕建議].freeze

  # 跨產品的固定系列：同樣的開場與名稱，讓觀眾認得、會追
  SERIES = {
    "背標偵探" => "老闆拿放大鏡看標示，一支拆解一個數字或名詞（專利、97%、1000mg…）",
    "真的假的" => "迷思快問快答，用 ⭕❌ 板或一句「真的假的？」開場，最後揭曉",
    "留言回覆" => "用回覆留言開場，一支回答一個問題，結尾邀請觀眾再留言",
  }.freeze

  # 把文字裡的 **粗體** 轉成 <strong>、【待填】標成紅字，其餘一律 escape。
  def video_topic_text(text)
    escaped = ERB::Util.html_escape(text.to_s)
    escaped
      .gsub(/\*\*(.+?)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
      .gsub(/【[^】]*】/) { |m| %(<span class="text-danger fw-500">#{m}</span>) }
      .html_safe
  end

  def video_topic_number(index)
    CIRCLED_NUMBERS[index] || "#{index + 1}."
  end
end
