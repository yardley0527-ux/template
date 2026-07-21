# frozen_string_literal: true

# CLI wrapper for shopline_orders:rehash_content_ids — owns the SyncRun
# lifecycle around ShoplineOrdersRehashService so a genuine crash, a
# lock-busy abort, and a collision-detected refusal are ALL visible as a
# "failed" SyncRun instead of silence (mirrors ShoplineOrdersDedupeRunner).
# Explicit require, not autoloaded.
class ShoplineOrdersRehashRunner
  def self.dry_run
    print_report(ShoplineOrdersRehashService.call(apply: false), apply: false)
  end

  def self.apply
    new.apply
  end

  def apply
    @sync_run = SyncRun.create!(source: "shopline_orders_rehash", status: "running", started_at: Time.current)

    report = ShoplineOrdersRehashService.call(apply: true)

    if report[:aborted]
      @sync_run.update!(status: "failed", finished_at: Time.current,
                        meta: { "aborted" => true, "reason" => report[:abort_reason] })
      puts "[shopline_orders:rehash_content_ids] ABORTED: #{report[:abort_reason]}"
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
    report[:verification][:clean]
  end

  # meta 只留聚合數字，不含 email/姓名/電話（rehash 的報表本來就沒有個資欄位）。
  def safe_meta(report)
    report.transform_values { |v| v.is_a?(BigDecimal) ? v.to_s : v }
  end

  def self.print_report(report, apply:)
    if report[:aborted]
      puts "[shopline_orders:rehash_content_ids] ABORTED: #{report[:abort_reason]}"
      return
    end

    puts "[shopline_orders:rehash_content_ids] mode=#{apply ? 'APPLY' : 'DRY_RUN'}"
    puts "  total_rows=#{report[:total_rows]} unchanged_rows=#{report[:unchanged_rows]} " \
         "changed_rows=#{report[:changed_rows]}"
    puts "  collision_groups=#{report[:collision_groups]} collision_rows=#{report[:collision_rows]} " \
         "safe_to_apply=#{report[:safe_to_apply]}"
    puts "  rows_missing_required_identity=#{report[:rows_missing_required_identity]} " \
         "ambiguous_occurrence_groups=#{report[:ambiguous_occurrence_groups]} " \
         "affected_import_runs=#{report[:affected_import_runs]}"

    if apply
      puts "  verification=#{report[:verification]}"
    else
      puts "  compute_seconds=#{report[:compute_seconds]} estimated_apply_seconds=#{report[:estimated_apply_seconds]}"
      puts "  re-run with APPLY=1 to write" if report[:safe_to_apply]
      puts "  DO NOT apply — collisions detected, investigate first" unless report[:safe_to_apply]
    end
  end
end
