require "test_helper"
require "quicsilver"

class QuicsilverTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Quicsilver::VERSION
  end

  def test_open_close
    handle = Quicsilver.open_connection
    assert handle
    Quicsilver.close_connection
  end
end