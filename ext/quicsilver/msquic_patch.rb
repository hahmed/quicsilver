# frozen_string_literal: true

require "digest"
require "open3"

# Keep the vendored revision pinned; carry the RESET_STREAM_AT changes as a
# reviewable patch until MsQuic provides the required wire format and semantics.
module MsquicPatch
  PATCH = File.expand_path("patches/reliable-reset.patch", __dir__)
  STAMP = ".quicsilver-patch"

  def self.apply!(source)
    return if check(source, "--reverse")
    unless check(source)
      raise "MsQuic reliable-reset patch does not apply cleanly; check the vendored revision and local edits"
    end

    output, status = Open3.capture2e("git", "apply", PATCH, chdir: source)
    raise "MsQuic patch failed: #{output}" unless status.success?
  end

  def self.check(source, *options)
    _output, status = Open3.capture2e("git", "apply", "--check", *options, PATCH, chdir: source)
    status.success?
  end

  def self.built?(source)
    File.read(File.join(source, "build", STAMP)) == Digest::SHA256.file(PATCH).hexdigest
  rescue Errno::ENOENT
    false
  end

  def self.record_build!(source)
    File.write(File.join(source, "build", STAMP), Digest::SHA256.file(PATCH).hexdigest)
  end
end
