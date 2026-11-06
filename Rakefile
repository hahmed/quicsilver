require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"
require_relative "ext/quicsilver/msquic_patch"
require_relative "lib/quicsilver/extension"

# Installed under the ABI version that built it, which is the path lib/quicsilver.rb already looks
# for first. A single shared lib/quicsilver/quicsilver.bundle is owned by whichever Ruby ran compile
# last, so switching Rubies between checkouts silently leaves a binary the next one cannot load —
# and `rake compile` considers itself up to date, so it does not rebuild. Version-scoped builds
# coexist instead, and each Ruby loads its own.
Rake::ExtensionTask.new("quicsilver") do |ext|
  ext.lib_dir = "lib/quicsilver/#{Quicsilver::Extension::DIR}"
end

# Keep `rake compile` useful in source checkouts, but let cibuildgem own
# extension compilation after the workflow has built and bundled MsQuic.
#
# bundle_msquic rewrites the rpath of the compiled extension, so it has to run
# *after* compile, not as a prerequisite of it. As a prerequisite on a clean
# checkout it patched whatever stale bundle was lying around and rake-compiler
# then overwrote it with an unsigned, rpath-less one.
unless ENV["CIBUILDGEM"]
  task :compile => :build_msquic
  Rake::Task[:compile].enhance { Rake::Task[:bundle_msquic].invoke }
end

# Where rake-compiler installed the extension for this Ruby's ABI. The flat
# path is only what a released gem ships; a build left there by a different
# Ruby gets picked up by the fallback require and fails inside dyld.
def extension_path
  versioned = "lib/quicsilver/#{Quicsilver::Extension::DIR}/quicsilver.bundle"
  File.exist?(versioned) ? versioned : 'lib/quicsilver/quicsilver.bundle'
end

# Copy MsQuic dylib next to the compiled extension for gem packaging
task :bundle_msquic do
  lib_dir = 'lib/quicsilver'
  if RUBY_PLATFORM =~ /darwin/
    dylib = 'vendor/msquic/build/bin/Release/libmsquic.2.dylib'
    bundle = extension_path
    if File.exist?(dylib)
      cp dylib, "#{lib_dir}/libmsquic.2.dylib"
      if File.exist?(bundle)
        # Update rpath so the bundle finds the dylib. @loader_path covers a flat
        # install; @loader_path/.. covers the versioned subdirectory. Both are
        # errors when already present, hence the `|| true`.
        sh "install_name_tool -add_rpath @loader_path #{bundle} 2>/dev/null || true"
        sh "install_name_tool -add_rpath @loader_path/.. #{bundle} 2>/dev/null || true"
        # install_name_tool invalidates the signature, and macOS then SIGKILLs
        # the process with no message at all. Re-sign ad-hoc.
        sh "codesign -f -s - #{bundle} #{lib_dir}/libmsquic.2.dylib"
      else
        warn "bundle_msquic: no compiled extension at #{bundle}; run `rake compile`"
      end
    end
  elsif RUBY_PLATFORM =~ /linux/
    so = 'vendor/msquic/build/bin/Release/libmsquic.so.2'
    cp so, "#{lib_dir}/libmsquic.so.2" if File.exist?(so)
  end
end

task :build => :bundle_msquic

task :setup do
  # Initialize git submodule if it doesn't exist
  unless File.exist?('vendor/msquic')
    sh 'git submodule add https://github.com/microsoft/msquic.git vendor/msquic'
    sh 'cd vendor/msquic && git submodule update --init --recursive'
  end
end

task :build_msquic => :setup do
  source = File.expand_path("vendor/msquic", __dir__)
  built_library = Dir[File.join(source, "build/bin/Release/libmsquic.{2.dylib,so.2}")].first

  # Reconfiguring picks up whatever toolchain is live, which is how a working
  # checkout starts failing to build gtest under a different shell. If the
  # patches are unchanged and the library is there, there is nothing to do.
  if MsquicPatch.built?(source) && built_library
    puts "MsQuic already built for the current patch set (#{built_library}); skipping."
    puts "Force a rebuild with: rm -rf vendor/msquic/build"
    next
  end

  MsquicPatch.apply!(source)
  cmake_args = ['-B build', '-DCMAKE_BUILD_TYPE=Release', '-DQUIC_TLS_LIB=quictls', '-DQUIC_LINUX_IOURING_ENABLED=OFF']
  if RUBY_PLATFORM =~ /darwin/
    cmake_args << '-DCMAKE_EXE_LINKER_FLAGS="-framework CoreServices"'
    cmake_args << '-DCMAKE_SHARED_LINKER_FLAGS="-framework CoreServices"'
    # Ensure QuicTLS uses Xcode SDK, not Homebrew OpenSSL
    sdk_path = `xcrun --show-sdk-path 2>/dev/null`.strip
    cmake_args << "-DCMAKE_OSX_SYSROOT=#{sdk_path}" unless sdk_path.empty?
  end
  # Override PATH so QuicTLS openssldir detection finds system openssl, not Homebrew
  env = { 'PATH' => "/usr/bin:#{ENV['PATH']}" }
  sh env, "cd vendor/msquic && cmake #{cmake_args.join(' ')}"
  sh env, 'cd vendor/msquic && cmake --build build --config Release'
  MsquicPatch.record_build!(File.expand_path("vendor/msquic", __dir__))
end

task :build => [:build_msquic, :compile]

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.ruby_opts << "-W0"
  t.test_files = FileList["test/**/*_test.rb"]
end

Rake::TestTask.new(:test_unit) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.ruby_opts << "-W0"
  t.test_files = FileList["test/**/*_test.rb"].reject { |f|
    f.include?("integration") || f.include?("stream_control") ||
    f =~ /quicsilver_test|event_loop_test/
  }
end

Rake::TestTask.new(:test_integration) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.ruby_opts << "-W0"
  t.test_files = FileList[
    "test/stream_control_integration_test.rb",
    "test/integration/**/*_test.rb",
    "test/quicsilver_test.rb",
    "test/event_loop_test.rb"
  ]
end

desc "Run unit and integration tests in parallel"
task :test_parallel do
  threads = []
  results = {}

  threads << Thread.new {
    results[:unit] = system("bundle exec rake test_unit 2>&1 > /dev/null")
  }
  threads << Thread.new {
    results[:integration] = system("bundle exec rake test_integration 2>&1 > /dev/null")
  }

  threads.each(&:join)
  unless results.values.all?
    abort "Tests failed: #{results.inspect}"
  end
end

namespace :benchmark do
  desc "Run throughput benchmark"
  task :throughput do
    ruby "benchmarks/throughput.rb"
  end

  desc "Run concurrency benchmark"
  task :concurrent do
    ruby "benchmarks/concurrent.rb"
  end

  desc "Run component micro-benchmarks"
  task :components do
    ruby "benchmarks/components.rb"
  end

  desc "Run all benchmarks"
  task :all => [:components, :throughput, :concurrent]
end

desc "Run all benchmarks"
task :benchmark => "benchmark:all"

task :default => :test
