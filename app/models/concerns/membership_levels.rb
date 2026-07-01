module MembershipLevels
  MEMBERSHIP_RANK = {
    "黑卡"    => 5,
    "金卡"    => 4,
    "銀卡"    => 3,
    "白卡"    => 2,
    "一般會員" => 1
  }.freeze

  TARGET_MEMBERSHIPS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze

  ALL_LEVELS = TARGET_MEMBERSHIPS

  LEVEL_KEYS = {
    "黑卡"    => "black",
    "金卡"    => "gold",
    "銀卡"    => "silver",
    "白卡"    => "white",
    "一般會員" => "normal"
  }.freeze
end
