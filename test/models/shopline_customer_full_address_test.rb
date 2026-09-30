# frozen_string_literal: true

require "test_helper"

class ShoplineCustomerFullAddressTest < ActiveSupport::TestCase
  def build(city: nil, address_2: nil, address_1: nil)
    ShoplineCustomer.new(email: "a@example.com", city: city, address_2: address_2, address_1: address_1)
  end

  test "joins city + district + street with no spaces" do
    assert_equal "新北市永和區環河西路一段19號17樓",
                 build(city: "新北市", address_2: "永和區", address_1: "環河西路一段19號17樓").full_address
  end

  test "returns nil when there is no street" do
    assert_nil build(city: "新北市", address_2: "永和區").full_address
    assert_nil build(city: "新北市", address_2: "永和區", address_1: "  ").full_address
  end

  test "does not prepend city/district when street already starts with the full address" do
    assert_equal "台北市中山區長安東路一段7巷10號4樓",
                 build(city: "台北市", address_2: "中山區", address_1: "台北市中山區長安東路一段7巷10號4樓").full_address
  end

  test "treats 台 and 臺 as the same city name" do
    assert_equal "臺北市中山區長安東路一段7巷10號4樓",
                 build(city: "台北市", address_2: "中山區", address_1: "臺北市中山區長安東路一段7巷10號4樓").full_address
  end

  test "keeps convenience-store and overseas addresses as written" do
    assert_equal "（7-11進益門市）新北市汐止區大同路二段314號",
                 build(city: "新北市", address_2: "汐止區", address_1: "（7-11進益門市）新北市汐止區大同路二段314號").full_address
    assert_equal "香港新界北區上水上水中心地下", build(city: "新界", address_2: "北區", address_1: "香港新界北區上水上水中心地下").full_address
  end

  test "only adds city when street already contains the district" do
    assert_equal "新北市汐止區大同路二段314號", build(city: "新北市", address_2: "汐止區", address_1: "汐止區大同路二段314號").full_address
  end

  test "works without city" do
    assert_equal "永和區環河西路", build(address_2: "永和區", address_1: "環河西路").full_address
  end
end
