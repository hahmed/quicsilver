require "test_helper"

class TransportServerIdTest < Minitest::Test
  def test_configure_transport_server_id_applies_hex_bytes
    singleton_class = class << Quicsilver; self; end
    original_method = singleton_class.instance_method(:apply_msquic_server_id)
    applied_bytes = nil

    singleton_class.define_method(:apply_msquic_server_id) do |bytes|
      applied_bytes = bytes
      true
    end

    Quicsilver.configure_transport_server_id("0000002A")

    assert_equal "0000002a", Quicsilver.transport_server_id
    assert_equal "\x00\x00\x00\x2a".b, applied_bytes
  ensure
    singleton_class.define_method(:apply_msquic_server_id, original_method) if original_method
  end

  def test_configure_transport_server_id_rejects_non_four_byte_hex_strings
    ["", "2a", "0000002", "00000002a", "zzzzzzzz"].each do |value|
      assert_raises(Quicsilver::ServerConfigurationError) do
        Quicsilver.configure_transport_server_id(value)
      end
    end
  end

  def test_configure_transport_server_id_rejects_non_string_values
    [42, :"0000002a", nil].each do |value|
      assert_raises(Quicsilver::ServerConfigurationError) do
        Quicsilver.configure_transport_server_id(value)
      end
    end
  end
end
