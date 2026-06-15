require 'csv'

class MemberContactsController < ApplicationController
  LEVELS       = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  INACTIVE_DAYS = 548

  def index
    @stats = build_stats
    @total = @stats.sum { |s| s[:total] }
    @total_active   = @stats.sum { |s| s[:active] }
    @total_inactive = @stats.sum { |s| s[:inactive] }
    @total_email    = @stats.sum { |s| s[:has_email] }
    @total_line     = @stats.sum { |s| s[:has_line] }

    last_run        = ImportRun.where(kind: "customers_report").order(started_at: :desc).first
    @last_import_at = last_run&.started_at
    @level_changes  = last_run ? MembershipLevelChange.where(import_run: last_run).recent : MembershipLevelChange.none
    @today_stat     = DailyMemberStat.find_or_initialize_by(stat_date: Date.today)
    @yesterday_stat = DailyMemberStat.find_by(stat_date: Date.yesterday)
    @recent_stats   = DailyMemberStat.recent(30).to_a
    @demographic    = Rails.cache.fetch("line_demographic", expires_in: 12.hours) do
      DailyMemberStat.fetch_demographic rescue nil
    end
  end

  def refresh_line
    stat = DailyMemberStat.fetch_and_upsert_line!
    if stat
      redirect_to member_contacts_path, notice: "LINE 數據已更新（好友數：#{stat.line_friends}）"
    else
      redirect_to member_contacts_path, alert: "LINE API 回傳資料尚未就緒，請稍後再試"
    end
  end

  def update_sl
    stat = DailyMemberStat.find_or_initialize_by(stat_date: Date.today)
    stat.assign_attributes(sl_params)
    if stat.save
      redirect_to member_contacts_path, notice: "Shopline 數據已儲存"
    else
      redirect_to member_contacts_path, alert: "儲存失敗：#{stat.errors.full_messages.join(', ')}"
    end
  end

  def export
    level    = params[:level].presence
    activity = params[:activity].presence  # 'active' | 'inactive' | nil = all

    scope = base_scope
    scope = scope.where(membership_level: level) if level
    scope = apply_activity_filter(scope, activity)

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "卡別", "Email", "Line ID", "手機", "狀態", "上次消費日"]
      scope.each do |row|
        csv << [
          row.full_name,
          row.membership_level,
          row.email,
          row.line_id,
          row.mobile_phone,
          row.last_order_date ? (row.last_order_date >= inactive_cutoff ? "活躍" : "不活躍") : "不活躍",
          row.last_order_date&.to_date
        ]
      end
    end

    suffix = [level, activity == 'active' ? '活躍' : activity == 'inactive' ? '不活躍' : nil].compact.join('_')
    suffix = '全部' if suffix.blank?
    send_data "\xEF\xBB\xBF#{csv_data}",
              filename: "會員聯絡名單_#{suffix}_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def build_stats
    cutoff   = inactive_cutoff
    all      = base_scope.group_by(&:membership_level)

    LEVELS.map do |level|
      rows    = all[level] || []
      active  = rows.count { |r| r.last_order_date && r.last_order_date >= cutoff }
      {
        level:     level,
        total:     rows.size,
        active:    active,
        inactive:  rows.size - active,
        has_email: rows.count { |r| r.email.present? },
        has_line:  rows.count { |r| r.line_id.present? }
      }
    end
  end

  def base_scope
    ShoplineCustomer
      .where.not(shopline_id: nil)
      .where(membership_level: LEVELS)
      .select("shopline_customers.full_name, shopline_customers.membership_level,
               shopline_customers.email, shopline_customers.line_id,
               shopline_customers.mobile_phone,
               cps.last_order_date")
      .joins("LEFT JOIN customer_purchase_summaries cps ON cps.email = shopline_customers.email")
  end

  def apply_activity_filter(scope, activity)
    case activity
    when 'active'
      scope.where("cps.last_order_date >= ?", inactive_cutoff)
    when 'inactive'
      scope.where("cps.last_order_date < ? OR cps.last_order_date IS NULL", inactive_cutoff)
    else
      scope
    end
  end

  def inactive_cutoff
    INACTIVE_DAYS.days.ago
  end

  def sl_params
    params.require(:daily_member_stat).permit(
      :sl_total_members, :sl_purchased_members,
      :line_bound_members, :line_and_sl_members, :unbound_purchased
    )
  end
end
