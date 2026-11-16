# Chloe 私訊話術卡：給客服回覆客人時參考，內容在 config/chloe_playbook.yml。
class ChloePlaybookController < ApplicationController
  CONFIG_PATH = Rails.root.join("config/chloe_playbook.yml")

  def index
    @playbook = self.class.playbook
  end

  def self.playbook
    YAML.load_file(CONFIG_PATH)
  end
end
