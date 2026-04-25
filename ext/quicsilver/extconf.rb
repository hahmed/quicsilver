require 'mkmf'

# Skip compilation if precompiled binary is already present
ext_dir = File.expand_path('../../lib/quicsilver', __dir__)
if File.exist?(File.join(ext_dir, 'quicsilver.bundle')) || File.exist?(File.join(ext_dir, 'quicsilver.so'))
  File.write('Makefile', "install:\n\t@echo 'Using precompiled binary'\n\nall:\n\t@echo 'Using precompiled binary'\n")
  exit
end

# On macOS, use Apple clang if available. Homebrew clang can't find
# system headers and produces broken binaries with MsQuic.
if RUBY_PLATFORM =~ /darwin/ && File.exist?("/usr/bin/clang")
  RbConfig::CONFIG["CC"] = "/usr/bin/clang"
  RbConfig::MAKEFILE_CONFIG["CC"] = "/usr/bin/clang"
end

# Find MSQUIC in the submodule
msquic_dir = File.expand_path('../../../vendor/msquic', __FILE__)

# Add MSQUIC include directory
$CFLAGS << " -I#{msquic_dir}/src/inc"
$CFLAGS << " -I#{msquic_dir}/src/inc/public"

# Add our fixes header
$CFLAGS << " -I#{File.expand_path('.', __FILE__)}"

# Add MSQUIC library directory
lib_dir = "#{msquic_dir}/build/bin/Release"
$LDFLAGS << " -L#{lib_dir}"

# Set rpath so the extension can find the library at runtime
$LDFLAGS << " -Wl,-rpath,#{lib_dir}"

# Find the MSQUIC library
unless find_library('msquic', nil, lib_dir)
  raise "MSQUIC library not found. Please run 'rake build_msquic' first."
end

create_makefile('quicsilver/quicsilver')