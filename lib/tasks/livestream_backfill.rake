# frozen_string_literal: true

# 方案 B PR1：直播場次一次性回填。邏輯在 app/services/livestream_backfill.rb，
# 資料來源 db/data/livestream_reconciliation.yml。
#
#   rails livestreams:backfill:preview            # 零寫入，產出 before/after CSV＋摘要
#   rails livestreams:backfill:apply              # 整批驗證通過才寫入；snapshot 存 SyncRun
#   rails livestreams:backfill:revert             # 預設 dry-run；CONFIRM=1 執行；
#                                                 #   SYNC_RUN_ID=n 指定 snapshot；FORCE=1 覆蓋後續修改
namespace :livestreams do
  namespace :backfill do
    desc "預覽回填（零寫入）：45 場 before/after CSV 與摘要"
    task preview: :environment do
      LivestreamBackfill.new.preview
    end

    desc "執行回填（單一 transaction；寫入前 snapshot 存 SyncRun；冪等）"
    task apply: :environment do
      LivestreamBackfill.new.apply
    end

    desc "還原回填（預設 dry-run，CONFIRM=1 執行；SYNC_RUN_ID 指定；FORCE=1 覆蓋後續修改）"
    task revert: :environment do
      LivestreamBackfill.new.revert(
        sync_run_id: ENV["SYNC_RUN_ID"].presence&.to_i,
        force: ENV["FORCE"] == "1",
        confirm: ENV["CONFIRM"] == "1"
      )
    end
  end
end
