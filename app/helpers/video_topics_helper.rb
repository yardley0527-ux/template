module VideoTopicsHelper
  CIRCLED_NUMBERS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  DEFAULT_SHOT_HEADERS = %w[鏡頭與動作 講解方向 圖片／字幕建議].freeze

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
