# frozen_string_literal: true

module CalendarEventsHelper
  # 把純文字裡的網址轉成可點連結（其餘內容照樣 escape）
  def auto_link_urls(text)
    escaped = ERB::Util.html_escape(text.to_s)
    linked = escaped.gsub(%r{https?://[^\s<>"]+}) do |url|
      %(<a href="#{url}" target="_blank" rel="noopener">#{url.length > 60 ? "#{url[0, 57]}…" : url}</a>)
    end
    linked.html_safe
  end
end
