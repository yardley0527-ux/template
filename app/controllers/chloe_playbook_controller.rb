# Chloe 私訊話術卡：給客服回覆客人時參考，內容在 config/chloe_playbook.yml。
class ChloePlaybookController < ApplicationController
  CONFIG_PATH = Rails.root.join("config/chloe_playbook.yml")

  def index
    @playbook = self.class.playbook
    @product = @playbook.fetch("products", []).find { |p| p["key"] == params[:tab] }
  end

  def self.playbook
    YAML.load_file(CONFIG_PATH)
  end
end
