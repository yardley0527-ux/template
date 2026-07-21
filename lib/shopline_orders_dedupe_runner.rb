# frozen_string_literal: true

# CLI wrapper for shopline_orders:dedupe_pattern_a — owns the SyncRun
# lifecycle around ShoplineOrdersDedupeService so a genuine crash (not just
# the service's own success/partial reporting) still leaves a "failed"
# record instead of silence. Explicit require, not autoloaded (mirrors
# CrmRollupRunner).
class ShoplineOrdersDedupeRunner
  def self.dry_run
    print_report(ShoplineOrdersDedupeService.call(apply: false), apply: false)
  end

  def self.apply
    new.apply
  end

  def apply
    @sync_run = SyncRun.create!(source: "shopline_orders_dedupe", status: "running", started_at: Time.current)

    report = ShoplineOrdersDedupeService.call(apply: true)

    if report[:aborted]
      @sync_run.update!(status: "failed", finished_at: Time.current,
                        meta: { "aborted" => true, "reason" => report[:abort_reason] })
      puts "[shopline_orders:dedupe_pattern_a] ABORTED: #{report[:abort_reason]}"
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
    report[:candidate_delete_count] == report[:verification][:deleted_row_count] &&
      report[:verification][:pattern_a_remaining].zero? &&
      report[:verification][:kept_ids_still_present] &&
      report[:verification][:deleted_ids_gone]
  end

  # meta 只留聚合數字（人數/筆數/金額/分類），不含 email/姓名/電話。
  def safe_meta(report)
    report.except(:applied).transform_values { |v| v.is_a?(BigDecimal) ? v.to_s : v }
  end

  def self.print_report(report, apply:)
    if report[:aborted]
      puts "[shopline_orders:dedupe_pattern_a] ABORTED: #{report[:abort_reason]}"
      return
    end

    puts "[shopline_orders:dedupe_pattern_a] mode=#{apply ? 'APPLY' : 'DRY_RUN'}"
    puts "  group_count=#{report[:group_count]} candidate_delete_count=#{report[:candidate_delete_count]} " \
         "retained_count=#{report[:retained_count]} skipped_count=#{report[:skipped_count]}"
    puts "  skipped_reasons=#{report[:skipped_reasons]}"
    puts "  affected_customers=#{report[:affected_customers]} affected_orders=#{report[:affected_orders]}"
    puts "  per_product=#{report[:per_product]}"
    puts "  amount_impact(checkout_amount_double_counted)=#{report[:amount_impact][:checkout_amount_double_counted]}"

    if apply
      puts "  dedupe_run_id=#{report[:dedupe_run_id]}"
      puts "  verification=#{report[:verification]}"
    else
      puts "  re-run with APPLY=1 to write (backs up every deleted row to shopline_orders_dedupe_backups first)"
    end
  end
end
