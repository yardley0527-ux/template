class LineBroadcastHighlightsController < ApplicationController
  def create
    @highlight = LineBroadcastHighlight.new(highlight_params)
    if @highlight.save
      render json: @highlight, status: :created
    else
      render json: { errors: @highlight.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @highlight = LineBroadcastHighlight.find(params[:id])
    Cloudinary::Api.delete_resources([@highlight.cloudinary_public_id]) rescue nil
    @highlight.destroy
    head :no_content
  end

  private

  def highlight_params
    params.require(:line_broadcast_highlight)
          .permit(:push_time, :topic, :image_url, :cloudinary_public_id, :note, :revenue, :read_rate, :position)
  end
end
