require 'mkmf'

# Find MSQUIC in the submodule
msquic_dir = File.expand_path('../../../vendor/msquic', __FILE__)

# Add MSQUIC include directory
$CFLAGS << " -I#{msquic_dir}/src/inc"
$CFLAGS << " -I#{msquic_dir}/src/inc/public"

# Add MSQUIC library directory
lib_dir = "#{msquic_dir}/build/bin/Release"
$LDFLAGS << " -L#{lib_dir}"

# Debug output
# puts "Looking for MSQUIC library in: #{lib_dir}"
# puts "Library files in directory:"
# Dir.glob("#{lib_dir}/*").each { |f| puts "  #{f}" }

# Find the MSQUIC library
unless find_library('msquic', nil, lib_dir)
  raise "MSQUIC library not found. Please run 'rake build_msquic' first."
end

create_makefile('quicsilver')