Rails.application.config.content_security_policy do |policy|
  policy.default_src :self, :https
  policy.font_src    :self, :https, :data
  policy.img_src     :self, :https, :data,
                     "https://res.cloudinary.com",
                     "https://upload-widget.cloudinary.com"
  policy.object_src  :none
  policy.style_src   :self, :https, :unsafe_inline

  policy.script_src  :self, :https,
                     "https://upload-widget.cloudinary.com",
                     :unsafe_inline

  policy.connect_src :self, :https,
                     "https://api.cloudinary.com",
                     "https://res.cloudinary.com",
                     "https://upload-widget.cloudinary.com"

  policy.frame_src   "https://upload-widget.cloudinary.com",
                     "https://www.instagram.com"
end