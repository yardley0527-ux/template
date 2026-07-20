class IgFollowersController < ApplicationController
  DATA_PATH = Rails.root.join("data", "ig_followers_data.json")

  NAMES = {
    "shengting_official"      => "苼莛 官方",
    "shengting.collagen"      => "膠原蛋白",
    "shengting.vitaminbczinc" => "全能",
    "shengting.bodyfit"       => "清纖粉",
    "shengting.slim"          => "薑黃",
    "shengting.hercare"       => "私密處",
    "shengting.vitaminDbone"  => "維生素D",
    "shengting.metabolic"     => "代謝錠",
    "shengting.fishoil"       => "魚油",
    "shengting.probiotic"     => "益生菌",
    "shengting.glow"          => "穀胱甘肽",
    "shengting.light"         => "抗老",
    "shengting.eyeprotect"    => "蝦紅素",
    "chloechao0527"           => "Chloe IG",
  }.freeze

  def index
    @data = File.exist?(DATA_PATH) ? JSON.parse(File.read(DATA_PATH)) : {}
    @last_updated = @data.values.flatten.map { |e| e["date"] }.max
    @names = NAMES
  end
end
