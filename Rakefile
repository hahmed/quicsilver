require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

Rake::ExtensionTask.new('quicsilver') do |ext|
  ext.lib_dir = 'lib/quicsilver'
end

task :setup do
  # Initialize git submodule if it doesn't exist
  unless File.exist?('vendor/msquic')
    sh 'git submodule add https://github.com/microsoft/msquic.git vendor/msquic'
    sh 'cd vendor/msquic && git submodule update --init --recursive'
  end
end

task :build_msquic => :setup do
  cmake_args = ['-B build', '-DCMAKE_BUILD_TYPE=Release']
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
end

task :build => [:build_msquic, :compile]

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

Rake::TestTask.new(:test_unit) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].reject { |f|
    f.include?("integration") || f.include?("stream_control") ||
    f =~ /quicsilver_test|event_loop_test/
  }
end

Rake::TestTask.new(:test_integration) do |t|
  t.libs << "test"
  t.libs << "lib"
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
