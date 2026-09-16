# frozen_string_literal: true

# 「重新產生本週報告」改成背景執行：上游快取刷新（尤其13個商品的回購週期
# 重算）+ 最多3次序列化的 Claude Opus API 往返，實測可能要好幾分鐘，不該讓
# 管理員在網頁上乾等。跟 ImportCustomersJob 是同一種模式（perform_later +
# 前端輪詢，見 imports 頁）。
#
# regeneration_started_at 由 controller 在 enqueue 前同步寫入（讓畫面立刻
# 顯示「產生中」，不用等 job 真的被撿起來），這裡的 ensure 負責清掉，
# 不管成功或失敗都要清，避免卡在「一直顯示產生中」。
class WeeklyBriefingRegenerationJob < ApplicationJob
  queue_as :default

  def perform(week_start)
    date = week_start.is_a?(Date) ? week_start : Date.parse(week_start.to_s)
    Rails.logger.info "[WeeklyBriefingRegenerationJob] starting week_start=#{date}"

    WeeklyBriefingRunner.call(week_start: date)

    Rails.logger.info "[WeeklyBriefingRegenerationJob] done week_start=#{date}"
  rescue StandardError => e
    Rails.logger.error "[WeeklyBriefingRegenerationJob] FAILED week_start=#{week_start} #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
  ensure
    briefing = WeeklyBriefing.find_by(week_start: date || week_start)
    briefing&.update_column(:regeneration_started_at, nil) # rubocop:disable Rails/SkipsModelValidations
  end
end
