# frozen_string_literal: true

# 某一天訂單簡報的手寫重點（AI 暫停時由本機 Claude Code 寫好存進來）。
# highlights 格式同 OrderBrief::Highlights：[{ "title" => ..., "details" => [...] }]
class OrderBriefNote < ApplicationRecord
  validates :report_date, presence: true, uniqueness: true
end
