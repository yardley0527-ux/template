module VideoTopicsHelper
  CIRCLED_NUMBERS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  # 把文字裡的 **粗體** 轉成 <strong>，其餘一律 escape。
  def video_topic_text(text)
    escaped = ERB::Util.html_escape(text.to_s)
    escaped.gsub(/\*\*(.+?)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }.html_safe
  end

  def video_topic_number(index)
    CIRCLED_NUMBERS[index] || "#{index + 1}."
  end
end
