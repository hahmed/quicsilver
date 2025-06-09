# Quicsilver

A Ruby client library for HTTP/3 and QUIC connections, powered by Microsoft's MSQUIC library.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'quicsilver'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install quicsilver

## Quick Start

```ruby
require 'quicsilver'

# Simple connection
Quicsilver.connect("example.com", 443) do |client|
  puts "Connected: #{client.connected?}"
  # TODO: Send HTTP/3 requests here
end

# Manual connection management
client = Quicsilver::Client.new
client.connect("localhost", 4433)
puts "Connection info: #{client.connection_info}"
client.disconnect
```

## Current Status

🚧 **Work in Progress**

## Testing

`rake test`

## Development

After checking out the repo, run:

```bash
bundle install
rake build_msquic  # Build the MSQUIC library
rake build         # Build the gem
rake test          # Run tests
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
