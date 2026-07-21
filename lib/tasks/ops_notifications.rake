# frozen_string_literal: true
#
# Notification Board generator. Idempotent, per-rule rescue, advisory-locked
# (NotificationsMaintenanceLock), records a SyncRun(source: "notifications").
# Never invoked via perform_later — production queue is :async (Phase 0A
# finding), so this is rake-only by design, same pattern as crm_rollup.
#
#   bundle exec rake ops:notifications                      # all 8 rules
#   RULE=vip_silent bundle exec rake ops:notifications       # one rule only
#
# Intended future schedule order (NOT wired to any Cron this round):
#   daily import -> crm_rollup:refresh_all -> ops:notifications

namespace :ops do
  desc "Generate/refresh Notification Board entries. RULE=<category> to run just one."
  task notifications: :environment do
    result = if ENV["RULE"].present?
      NotificationEngine.run_rule(ENV["RULE"])
    else
      NotificationEngine.run_all
    end

    if result[:aborted]
      puts "[ops:notifications] ABORTED: #{result[:abort_reason]}"
      next
    end

    puts "[ops:notifications] sync_run_id=#{result[:sync_run_id]} status=#{result[:status]}"
    result[:per_rule].each do |category, stats|
      puts "  #{category}: hit=#{stats[:hit_count]} created=#{stats[:created]} " \
           "updated=#{stats[:updated]} auto_resolved=#{stats[:auto_resolved]} error=#{stats[:error] || 'none'}"
    end
  end
end
