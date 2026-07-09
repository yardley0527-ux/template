# frozen_string_literal: true

module ApplicationHelper
  # 追蹤備註編輯者的顯示名稱（帳號 → 中文名），沒對到的帳號直接顯示 username
  NOTE_EDITOR_NAMES = {
    "crmdata" => "珍珍",
    "owner"   => "Chloe"
  }.freeze

  def note_editor_name(username)
    NOTE_EDITOR_NAMES.fetch(username.to_s, username)
  end

  def class_if_current_page(entry:)
    selected = is_current_page?(entry)

    class_name = 'active'
    class_name += ' open' unless current_page?(entry[:href])
    class_name if selected
  end

  def filter_tags_from_title(parents:, sub_entry:)
    result =
      (parents + [sub_entry]).collect { |item| item[:title] }.join(' ').downcase

    result = "#{result} #{sub_entry[:tags]}" if sub_entry[:tags].present?

    result
  end

  def i18n_from_title(prefix:, title:)
    "#{prefix}#{title.downcase.gsub(' ', '_')}"
  end

  private

  def is_current_page?(entry)
    if current_page?(entry[:href])
      true
    elsif entry[:children]
      entry[:children].any?(&method(:is_current_page?))
    else
      false
    end
  end
end
