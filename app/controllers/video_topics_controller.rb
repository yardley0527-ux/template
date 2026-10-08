# 產品拍片主題：每個產品的影片方向、分鏡、照片準備與拍攝注意事項。
# 內容寫在 config/video_topics.yml，新增產品時請 Claude 加進去。
class VideoTopicsController < ApplicationController
  CONFIG_PATH = Rails.root.join("config/video_topics.yml")

  def index
    @products = self.class.products
    @product = @products.find { |p| p["key"] == params[:product] } || @products.first
  end

  def self.products
    YAML.load_file(CONFIG_PATH).fetch("products", [])
  end
end
