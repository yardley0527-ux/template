# frozen_string_literal: true

# /ig_inbox「重新整理總結」按鈕：Claude 要跑一兩分鐘，改背景執行。
class IgInboxDigestJob < ApplicationJob
  queue_as :default

  def perform(day)
    IgInbox::Digest.call(Date.parse(day), force: true)
  end
end
