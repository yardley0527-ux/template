class MessageTemplateImagesController < ApplicationController
  def create
    block = MessageTemplateBlock.find(params[:message_template_block_id])
    file  = params[:file]

    result = Cloudinary::Uploader.upload(file.tempfile.path,
      folder: "message_templates",
      resource_type: "image"
    )

    position = block.message_template_images.maximum(:position).to_i + 1
    img = block.message_template_images.create!(
      cloudinary_public_id: result["public_id"],
      url: result["secure_url"],
      position: position
    )

    card_html = render_to_string(
      partial: "message_templates/message_card",
      locals: { template: block.message_template.reload }
    )

    render json: { id: img.id, url: img.url, card_html: card_html }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    img   = MessageTemplateImage.find(params[:id])
    block = img.message_template_block
    Cloudinary::Uploader.destroy(img.cloudinary_public_id) rescue nil
    img.destroy

    card_html = render_to_string(
      partial: "message_templates/message_card",
      locals: { template: block.message_template.reload }
    )
    render json: { card_html: card_html }
  end
end
