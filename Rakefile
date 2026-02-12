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
  end
  sh "cd vendor/msquic && cmake #{cmake_args.join(' ')}"
  sh 'cd vendor/msquic && cmake --build build --config Release'
end

task :build => [:build_msquic, :compile]

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
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
