class MembershipLevelStatsService
  def self.call(event_emails:)
    new(Array(event_emails)).call
  end

  def initialize(event_emails)
    @event_emails = event_emails
  end

  def call
    level_counts    = ShoplineCustomer
      .where.not(shopline_id: nil)
      .where(membership_level: MembershipLevels::TARGET_MEMBERSHIPS)
      .group(:membership_level).count

    emails_by_level = ShoplineCustomer
      .where(membership_level: MembershipLevels::TARGET_MEMBERSHIPS)
      .where.not(email: [nil, ""])
      .pluck(:membership_level, :email)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }

    MembershipLevels::TARGET_MEMBERSHIPS.filter_map do |level|
      total = level_counts[level] || 0
      next if total.zero?
      emails   = emails_by_level[level] || []
      attended = (emails & @event_emails).size
      { level: level, total: total, attended: attended, rate: pct(attended, total) }
    end
  end

  private

  def pct(num, den)
    return 0.0 if den.zero?
    (num.to_f / den * 100).round(1)
  end
end
