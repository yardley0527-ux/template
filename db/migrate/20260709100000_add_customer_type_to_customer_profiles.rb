# frozen_string_literal: true

class AddCustomerTypeToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :customer_type, :string
  end
end
