require 'csv'

class MemberContactsController < ApplicationController
  LEVELS       = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  INACTIVE_DAYS = 365

  def index
    @stats = build_stats
    @total = @stats.sum { |s| s[:total] }
    @total_active   = @stats.sum { |s| s[:active] }
    @total_inactive = @stats.sum { |s| s[:inactive] }
    @total_email    = @stats.sum { |s| s[:has_email] }
    @total_line     = @stats.sum { |s| s[:has_line] }
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
end
