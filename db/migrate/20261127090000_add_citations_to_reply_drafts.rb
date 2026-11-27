# frozen_string_literal: true

class AddCitationsToReplyDrafts < ActiveRecord::Migration[7.1]
  def change
    # { "sources" => [{ "ref", "question", "quote" }], "conflicts" => [{ "ref", "question", "quote", "note" }] }
    add_column :reply_drafts, :citations, :jsonb, default: {}, null: false
  end
end
