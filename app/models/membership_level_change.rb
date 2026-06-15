class MembershipLevelChange < ApplicationRecord
  belongs_to :import_run

  LEVEL_RANK = {
    "黑卡"   => 5,
    "金卡"   => 4,
    "銀卡"   => 3,
    "白卡"   => 2,
    "一般會員" => 1
  }.freeze

  scope :upgrades,   -> { where(direction: "upgrade") }
  scope :downgrades, -> { where(direction: "downgrade") }
  scope :recent,     -> { order(changed_at: :desc) }

  def self.detect_and_record!(import_run, before_snapshot)
    now = Time.zone.now
    after_snapshot = ShoplineCustomer
      .where.not(shopline_id: nil)
      .where.not(membership_level: nil)
      .pluck(:shopline_id, :full_name, :email, :membership_level)
      .each_with_object({}) { |(sid, name, email, lvl), h| h[sid] = { level: lvl, name: name, email: email } }

    changes = []
    (before_snapshot.keys & after_snapshot.keys).each do |sid|
      from = before_snapshot[sid][:level]
      to   = after_snapshot[sid][:level]
      next if from == to
      from_rank = LEVEL_RANK[from]
      to_rank   = LEVEL_RANK[to]
      next unless from_rank && to_rank

      direction = to_rank > from_rank ? "upgrade" : "downgrade"
      changes << {
        import_run_id: import_run.id,
        shopline_id:   sid,
        full_name:     after_snapshot[sid][:name],
        email:         after_snapshot[sid][:email],
        from_level:    from,
        to_level:      to,
        direction:     direction,
        changed_at:    now
      }
    end

    insert_all(changes) if changes.any?
    changes.size
  end
end
