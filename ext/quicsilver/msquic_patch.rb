# frozen_string_literal: true

require "digest"
require "open3"

# Keep the vendored revision pinned; carry our MsQuic changes as reviewable
# patches until upstream provides the required wire format and accessors.
#
# Each patch is applied and checked independently so one can be dropped when
# it lands upstream without disturbing the others. The build stamp digests all
# of them together: any change to any patch invalidates the built tree.
#
# REVIEW THIS ON EVERY MsQuic UPGRADE. A failed `git apply` is loud, but not
# every conflict is:
#
# 1. Did upstream implement what a patch works around? Delete the patch
#    rather than carrying a shim that shadows the real feature.
# 2. stream-final-size.patch adds a field to the PEER_SEND_ABORTED event
#    struct. Check upstream has not added its own field there, and that
#    QuicStreamIndicatePeerSendAbortedEvent still has the stream in scope.
# 3. A patch can still apply cleanly onto changed semantics. Re-read the hunks
#    against the new source; "it applied" is not "it is still correct".
# 4. Re-run the tests that prove each patch does its job, not just the suite.
#    For final size: test/integration/stream_lifetime_test.rb -n /final_size/.
module MsquicPatch
  PATCHES = [
    # RESET_STREAM_AT wire format and semantics.
    File.expand_path("patches/reliable-reset.patch", __dir__),
    # Read the settled final size of a received stream, which WT_MAX_DATA
    # session accounting needs (draft-ietf-webtrans-http3-16 5.4).
    File.expand_path("patches/stream-final-size.patch", __dir__)
  ].freeze

  STAMP = ".quicsilver-patch"

  def self.apply!(source)
    PATCHES.each do |patch|
      next if check(source, patch, "--reverse")

      unless check(source, patch)
        raise "MsQuic patch #{File.basename(patch)} does not apply cleanly; " \
              "check the vendored revision and local edits"
      end

      output, status = Open3.capture2e("git", "apply", patch, chdir: source)
      raise "MsQuic patch #{File.basename(patch)} failed: #{output}" unless status.success?
    end
  end

  def self.check(source, patch, *options)
    _output, status = Open3.capture2e("git", "apply", "--check", *options, patch, chdir: source)
    status.success?
  end

  def self.digest
    Digest::SHA256.hexdigest(PATCHES.map { |patch| Digest::SHA256.file(patch).hexdigest }.join)
  end

  def self.built?(source)
    File.read(File.join(source, "build", STAMP)) == digest
  rescue Errno::ENOENT
    false
  end

  def self.record_build!(source)
    File.write(File.join(source, "build", STAMP), digest)
  end
end
