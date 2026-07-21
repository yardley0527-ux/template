# frozen_string_literal: true

# CLI wrapper for shopline_orders:restore_dedupe_run — owns the SyncRun
# lifecycle around ShoplineOrdersRestoreService (mirrors
# ShoplineOrdersDedupeRunner / ShoplineOrdersRehashRunner).
class ShoplineOrdersRestoreRunner
  def self.dry_run(dedupe_run_id:)
    print_report(ShoplineOrdersRestoreService.call(dedupe_run_id: dedupe_run_id, apply: false), apply: false)
  end

  def self.apply(dedupe_run_id:)
    new(dedupe_run_id: dedupe_run_id).apply
  end

  def initialize(dedupe_run_id:)
    @dedupe_run_id = dedupe_run_id
  end

  def apply
    @sync_run = SyncRun.create!(source: "shopline_orders_restore", status: "running", started_at: Time.current,
                                meta: { "dedupe_run_id" => @dedupe_run_id })

    report = ShoplineOrdersRestoreService.call(dedupe_run_id: @dedupe_run_id, apply: true)

    if report[:aborted]
      @sync_run.update!(status: "failed", finished_at: Time.current,
                        meta: { "aborted" => true, "reason" => report[:abort_reason] })
      puts "[shopline_orders:restore_dedupe_run] ABORTED: #{report[:abort_reason]}"
      return report
    end

    status = clean_apply?(report) ? "success" : "partial"
    @sync_run.update!(status: status, finished_at: Time.current, meta: safe_meta(report))
    self.class.print_report(report, apply: true)
    puts "  sync_run_id=#{@sync_run.id} status=#{status}"
    report
  rescue StandardError => e
    @sync_run&.update!(status: "failed", finished_at: Time.current, meta: { "error" => e.class.name })
    raise
  end

  def clean_apply?(report)
    return true if report[:restored_count].zero?

    report[:verification][:restored_ids_present] && report[:verification][:backups_marked_restored]
  end

  def safe_meta(report)
    report.transform_values { |v| v.is_a?(BigDecimal) ? v.to_s : v }
  end

  def self.print_report(report, apply:)
    if report[:aborted]
      puts "[shopline_orders:restore_dedupe_run] ABORTED: #{report[:abort_reason]}"
      return
    end

    puts "[shopline_orders:restore_dedupe_run] mode=#{apply ? 'APPLY' : 'DRY_RUN'} dedupe_run_id=#{report[:dedupe_run_id]}"
    puts "  total_backed_up=#{report[:total_backed_up]} pending_restore_count=#{report[:pending_restore_count]} " \
         "already_restored_count=#{report[:already_restored_count]}"
    puts "  affected_customers=#{report[:affected_customers]} affected_orders=#{report[:affected_orders]}"

    if apply
      puts "  restored_count=#{report[:restored_count]}"
      puts "  verification=#{report[:verification]}" if report[:verification]
    else
      puts "  re-run with APPLY=1 to write (then run shopline_orders:rehash_content_ids APPLY=1 next)"
    end
  end
end
