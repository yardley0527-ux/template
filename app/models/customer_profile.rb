class CustomerProfile < ApplicationRecord
  belongs_to :shopline_customer, class_name: "ShoplineCustomer"
end