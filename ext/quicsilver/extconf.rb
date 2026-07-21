require 'mkmf'
require 'fileutils'

ext_dir = File.expand_path('../../lib/quicsilver', __dir__)
gemspec_dir = File.expand_path('../..', __dir__)

# Skip compilation for installed platform gems that already contain a native
# extension. In a source checkout we must always compile for the current Ruby;
# otherwise a stale lib/quicsilver/quicsilver.bundle from another Ruby ABI can
# prevent rake-compiler from producing the extension it is about to copy.
source_checkout = File.exist?(File.expand_path("../../.git", __dir__))
precompiled_binary = File.exist?(File.join(ext_dir, "quicsilver.bundle")) ||
  File.exist?(File.join(ext_dir, "quicsilver.so"))

if precompiled_binary && !source_checkout
  File.write("Makefile", "install:\n\t@echo 'Using precompiled binary'\n\nall:\n\t@echo 'Using precompiled binary'\n")
  exit
end

# On macOS, use Apple clang if available. Homebrew clang can't find
# system headers and produces broken binaries with MsQuic.
if RUBY_PLATFORM =~ /darwin/ && File.exist?("/usr/bin/clang")
  RbConfig::CONFIG["CC"] = "/usr/bin/clang"
  RbConfig::MAKEFILE_CONFIG["CC"] = "/usr/bin/clang"
end

# --- Locate libmsquic ---
# Priority:
#   1. Vendored submodule build (vendor/msquic/build/bin/Release/)
#   2. Shipped dylib in lib/quicsilver/ (checked into git, always available)
#   3. Auto-build from submodule source

msquic_dir = File.expand_path('../../../vendor/msquic', __FILE__)
vendor_lib_dir = "#{msquic_dir}/build/bin/Release"
shipped_lib_dir = ext_dir  # lib/quicsilver/ contains libmsquic.2.dylib

# Find which directory has libmsquic
lib_dir = if File.exist?(vendor_lib_dir) && Dir.glob("#{vendor_lib_dir}/libmsquic.*").any?
  puts "Using vendored MsQuic from #{vendor_lib_dir}"
  vendor_lib_dir
elsif Dir.glob("#{shipped_lib_dir}/libmsquic*").any?
  puts "Using shipped libmsquic from #{shipped_lib_dir}"
  shipped_lib_dir
else
  # Auto-build from submodule
  puts "MsQuic not found, building from source..."

  unless File.exist?(File.join(msquic_dir, 'CMakeLists.txt'))
    Dir.chdir(gemspec_dir) do
      system('git submodule update --init --recursive vendor/msquic') or
        raise 'Failed to initialize MsQuic submodule'
    end
  end

  cmake_args = ['-B build', '-DCMAKE_BUILD_TYPE=Release']
  if RUBY_PLATFORM =~ /darwin/
    cmake_args << '-DCMAKE_EXE_LINKER_FLAGS="-framework CoreServices"'
    cmake_args << '-DCMAKE_SHARED_LINKER_FLAGS="-framework CoreServices"'
    sdk_path = `xcrun --show-sdk-path 2>/dev/null`.strip
    cmake_args << "-DCMAKE_OSX_SYSROOT=#{sdk_path}" unless sdk_path.empty?
  end

  env = { 'PATH' => "/usr/bin:#{ENV['PATH']}" }
  Dir.chdir(msquic_dir) do
    system(env, "cmake #{cmake_args.join(' ')}") or raise 'MsQuic cmake configure failed'
    system(env, 'cmake --build build --config Release') or raise 'MsQuic build failed'
  end

  vendor_lib_dir
end

# Copy MsQuic next to the Ruby extension so @loader_path/@rpath works for
# Bundler git installs as well as local checkouts. GitHub checkouts do not have
# generated dylibs checked in, so when we build MsQuic from the submodule we
# must also place the runtime library where `require "quicsilver"` expects it.
FileUtils.mkdir_p(ext_dir)
Dir.glob(File.join(lib_dir, "libmsquic*")) do |library|
  target = File.join(ext_dir, File.basename(library))
  next if File.identical?(library, target) rescue false

  FileUtils.cp(library, target)
end

# --- Locate MsQuic headers ---
# Available from vendored submodule or shipped in ext/quicsilver/include/
msquic_inc = "#{msquic_dir}/src/inc"
msquic_inc_public = "#{msquic_dir}/src/inc/public"
shipped_inc = File.join(File.dirname(__FILE__), 'include')

if File.exist?(msquic_inc)
  $CFLAGS << " -I#{msquic_inc}"
  $CFLAGS << " -I#{msquic_inc_public}"
elsif File.exist?(shipped_inc)
  $CFLAGS << " -I#{shipped_inc}"
end

$CFLAGS << " -I#{File.expand_path('.', __FILE__)}"

$LDFLAGS << " -L#{lib_dir}"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -Wl,-rpath,@loader_path"
  $LDFLAGS << " -Wl,-rpath,@loader_path/.."
else
  $LDFLAGS << " -Wl,-rpath,\\$$ORIGIN"
  $LDFLAGS << " -Wl,-rpath,\\$$ORIGIN/.."
end

unless find_library('msquic', nil, lib_dir)
  raise "MSQUIC library not found in #{lib_dir}. " \
        "Ensure lib/quicsilver/libmsquic.2.dylib exists or run 'rake build_msquic'."
end

create_makefile('quicsilver/quicsilver')