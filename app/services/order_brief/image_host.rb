# frozen_string_literal: true

require "securerandom"

module OrderBrief
  # 把 TableImage 的 PDF 上傳到 Cloudinary，取回 LINE 圖片訊息要的兩個 PNG 網址
  # （LINE 只收 https 的 JPEG/PNG：原圖 ≤ 10MB、預覽圖 ≤ 1MB）。
  # 檔名用隨機字串，網址猜不到；圖片裡有客人姓名，不要把網址貼到公開地方。
  class ImageHost
    FOLDER = "line_order_briefs"

    def self.configured?
      config.cloud_name.present? && config.api_key.present? && config.api_secret.present?
    end

    # credentials 沒設 Cloudinary 時，退回 Render 上的 CLOUDINARY_* 環境變數
    def self.config
      c = Cloudinary.config
      c.cloud_name ||= ENV["CLOUDINARY_CLOUD_NAME"].presence
      c.api_key ||= ENV["CLOUDINARY_API_KEY"].presence
      c.api_secret ||= ENV["CLOUDINARY_API_SECRET"].presence
      c
    end

    # 回傳 LINE image message
    def self.upload(pdf, day:, name:)
      config
      public_id = "#{FOLDER}/#{day.iso8601}-#{name}-#{SecureRandom.hex(8)}"
      Tempfile.create(["brief", ".pdf"]) do |f|
        f.binmode
        f.write(pdf)
        f.flush
        Cloudinary::Uploader.upload(f.path, public_id: public_id, resource_type: "image", overwrite: true)
      end
      original = Cloudinary::Utils.cloudinary_url(public_id, format: "png", secure: true,
                                                             transformation: [{ density: 150 }, { width: 1800, crop: "limit" }])
      preview = Cloudinary::Utils.cloudinary_url(public_id, format: "jpg", secure: true,
                                                            transformation: [{ density: 72 }, { width: 600, crop: "limit", quality: 80 }])
      { type: "image", originalContentUrl: original, previewImageUrl: preview }
    end
  end
end
