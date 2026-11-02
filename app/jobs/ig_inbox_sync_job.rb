# frozen_string_literal: true

# 同步 IG 私訊並分類新訊息。每小時由 manychat:sync 順便跑，/ig_inbox 打開時資料超過 5 分鐘也會在背景跑一次。
class IgInboxSyncJob < ApplicationJob
  queue_as :default

  def perform
    return if SyncRun.where(source: "ig_inbox", status: "running").where("started_at > ?", 10.minutes.ago).exists?

    run = SyncRun.create!(source: "ig_inbox", started_at: Time.current)
    synced = IgInbox::Sync.call
    classified = IgInbox::Classifier.call
    run.update!(status: synced[:errors].empty? ? "success" : "partial", finished_at: Time.current,
                meta: { synced: synced.except(:errors), classified: classified }, error_messages: synced[:errors])
  rescue StandardError => e
    run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
    raise
  end
end
