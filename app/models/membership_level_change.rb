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

    candidate_sids = (before_snapshot.keys & after_snapshot.keys)
                       .select { |sid| before_snapshot[sid][:level] != after_snapshot[sid][:level] }

    # 同一人最近一次記錄的 to_level 若跟這次偵測到的一樣，代表這不是新的淨變化，
    # 而是卡別在兩次匯入之間被別的流程短暫改回舊值、又被這次匯入修正回原本就有紀錄的
    # 現況——不記錄，避免同一次真實異動被重複灌水（見 2026-09-08 稽核）。
    last_to_level_by_sid = where(shopline_id: candidate_sids)
      .select("DISTINCT ON (shopline_id) shopline_id, to_level")
      .order(:shopline_id, changed_at: :desc)
      .to_h { |r| [r.shopline_id, r.to_level] }

    changes = []
    candidate_sids.each do |sid|
      from = before_snapshot[sid][:level]
      to   = after_snapshot[sid][:level]
      next if last_to_level_by_sid[sid] == to
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
