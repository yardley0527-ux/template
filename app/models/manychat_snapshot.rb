class ManychatSnapshot < ApplicationRecord
  has_many :manychat_iguids, dependent: :destroy

  ACCOUNT_LABELS = { 'chloe' => 'Chloe Chao', 'official' => '苼莛國際生技' }.freeze

  def account_label
    ACCOUNT_LABELS[account_type]
  end
end
