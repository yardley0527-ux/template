# frozen_string_literal: true
#
# Notification Board generator. Idempotent, per-rule rescue, advisory-locked
# (NotificationsMaintenanceLock), records a SyncRun(source: "notifications").
# Never invoked via perform_later — production queue is :async (Phase 0A
# finding), so this is rake-only by design, same pattern as crm_rollup.
#
#   bundle exec rake ops:notifications                      # all rules (see NotificationEngine::RULES)
#   RULE=vip_silent bundle exec rake ops:notifications       # one rule only
#   DRY_RUN=1 bundle exec rake ops:notifications             # read-only preview, no writes at all
#
# Intended future schedule order (NOT wired to any Cron this round):
#   daily import -> crm_rollup:refresh_all -> ops:notifications

namespace :ops do
  desc "Generate/refresh Notification Board entries. RULE=<category> to run just one. DRY_RUN=1 for a read-only preview."
  task notifications: :environment do
    categories = ENV["RULE"].present? ? [ENV["RULE"]] : NotificationEngine::RULES.keys

    if ENV["DRY_RUN"].present?
      result = NotificationEngine.dry_run(categories)
      puts "[ops:notifications] DRY_RUN — no notifications/sync_runs rows were created, updated, or resolved"
      result[:per_rule].each do |category, stats|
        puts "  #{category}: matched=#{stats[:matched_subjects]} to_create=#{stats[:cards_to_create]} " \
             "to_update=#{stats[:cards_to_update]} to_resolve=#{stats[:cards_to_resolve]} " \
             "severity=#{stats[:severity_distribution]} metadata_bytes≈#{stats[:metadata_bytes_estimate]} " \
             "query_s=#{stats[:query_seconds]} error=#{stats[:error] || 'none'}"
      end
      next
    end

    result = ENV["RULE"].present? ? NotificationEngine.run_rule(ENV["RULE"]) : NotificationEngine.run_all

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
