# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'pathname'
require 'stringio'
require 'rbconfig'
require 'English'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# Top-level execution in main.rb is guarded by `__FILE__ == $PROGRAM_NAME`,
# so requiring it only defines the functions under test.
require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @top_idx  = -1
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      @top_idx = (@top_idx + 1) % GROUP_COLORS.size
      output.puts "  #{GROUP_COLORS[@top_idx]}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Subprocess Helpers ───────────────────────────────────────────────────────

# A fake `xcodebuild` that succeeds without touching the real toolchain. It is
# placed first on PATH so main.rb's shell-out resolves to it instead of Xcode.
XCODEBUILD_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild invoked"
  exit 0
SH

# A fake `xcodebuild` that fails, to exercise the runCommand error branch.
XCODEBUILD_FAILING_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild failure details" >&2
  exit 65
SH

def with_xcodebuild_stub(source = XCODEBUILD_STUB_SOURCE)
  stub_dir = Dir.mktmpdir('xcodebuild_stub')
  stub     = File.join(stub_dir, 'xcodebuild')
  File.write(stub, source)
  FileUtils.chmod(0o755, stub)
  yield stub_dir
ensure
  FileUtils.rm_rf(stub_dir)
end

# Run main.rb in a child process with a controlled ENV.
# Keys left as nil are explicitly unset in the child, which isolates the
# missing-variable tests from the ambient environment.
def run_main(env = {}, stub_source: XCODEBUILD_STUB_SOURCE)
  with_xcodebuild_stub(stub_source) do |stub_dir|
    clean_env = {
      'AC_REPOSITORY_DIR'              => nil,
      'AC_TEMP_DIR'                    => nil,
      'AC_PROJECT_PATH'                => nil,
      'AC_SCHEME'                      => nil,
      'AC_DESTINATION'                 => nil,
      'AC_CONFIGURATION_NAME'          => nil,
      'AC_COMPILER_INDEX_STORE_ENABLE' => nil,
      'AC_ARCHIVE_FLAGS'               => nil,
      'AC_ENV_FILE_PATH'               => nil,
      'PATH'                           => "#{stub_dir}:#{ENV.fetch('PATH', '')}"
    }.merge(env)

    Open3.capture3(clean_env, "ruby #{MAIN_RB}")
  end
end

# Every variable main.rb needs to reach the build step.
def full_env(tmpdir)
  {
    'AC_TEMP_DIR'                    => tmpdir,
    'AC_PROJECT_PATH'                => 'App.xcodeproj',
    'AC_SCHEME'                      => 'MyScheme',
    'AC_COMPILER_INDEX_STORE_ENABLE' => 'NO',
    'AC_ENV_FILE_PATH'               => File.join(tmpdir, 'env_file')
  }
end

# ─── Tests ────────────────────────────────────────────────────────────────────

# ─── 1. env_has_key ───────────────────────────────────────────────────────────
RSpec.describe '#env_has_key' do
  around do |example|
    had = ENV.key?('_AC_TEST_VAR')
    old = ENV['_AC_TEST_VAR']
    example.run
    had ? ENV['_AC_TEST_VAR'] = old : ENV.delete('_AC_TEST_VAR')
  end

  before { allow($stderr).to receive(:write) }

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_AC_TEST_VAR'] = 'hello'
      expect(env_has_key('_AC_TEST_VAR')).to eq('hello')
    end

    it 'returns a value that only contains whitespace' do
      ENV['_AC_TEST_VAR'] = ' '
      expect(env_has_key('_AC_TEST_VAR')).to eq(' ')
    end

    it 'returns the value verbatim, without trimming' do
      ENV['_AC_TEST_VAR'] = "  spaced  "
      expect(env_has_key('_AC_TEST_VAR')).to eq('  spaced  ')
    end
  end

  context 'negative path' do
    it 'aborts when the key is missing' do
      ENV.delete('_AC_TEST_VAR')
      expect { env_has_key('_AC_TEST_VAR') }.to raise_error(SystemExit)
    end

    it 'aborts when the value is an empty string' do
      ENV['_AC_TEST_VAR'] = ''
      expect { env_has_key('_AC_TEST_VAR') }.to raise_error(SystemExit)
    end

    it 'names the missing key in the abort message' do
      ENV.delete('_AC_TEST_VAR')
      expect { env_has_key('_AC_TEST_VAR') }
        .to raise_error(SystemExit, /Missing _AC_TEST_VAR\./)
    end

    it 'raises TypeError when the key itself is nil' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─── 2. runCommand ────────────────────────────────────────────────────────────
RSpec.describe '#runCommand' do
  before { allow($stdout).to receive(:puts) }

  context 'positive path' do
    it 'returns without raising for a successful command' do
      expect { runCommand('echo hi') }.not_to raise_error
    end

    it 'echoes the command it is about to run' do
      expect($stdout).to receive(:puts).with('@@[command] echo hi')
      runCommand('echo hi')
    end

    it 'succeeds for a command that writes to stderr but exits zero' do
      expect { runCommand('bash -c "echo noise >&2; exit 0"') }.not_to raise_error
    end

    it 'streams multi-line stdout without raising' do
      expect { runCommand('printf "a\\nb\\nc\\n"') }.not_to raise_error
    end
  end

  context 'negative path' do
    it 'raises when the command exits non-zero' do
      expect { runCommand('bash -c "exit 1"') }.to raise_error(RuntimeError)
    end

    it 'raises with the stderr output as the message' do
      expect { runCommand('bash -c "echo failure details >&2; exit 1"') }
        .to raise_error(RuntimeError, /failure details/)
    end

    it 'raises Errno::ENOENT for a non-existent executable' do
      expect { runCommand('ac_definitely_not_a_real_binary_xyz') }
        .to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT for an empty command' do
      expect { runCommand('') }.to raise_error(Errno::ENOENT)
    end

    it 'raises TypeError for a nil command' do
      expect { runCommand(nil) }.to raise_error(TypeError)
    end
  end
end

# ─── 3. build – command construction ──────────────────────────────────────────
RSpec.describe '#build' do
  let(:base_args) do
    {
      repository_path:  nil,
      temporary_path:   '/tmp/appcircle_build_for_testing',
      project_path:     'App.xcodeproj',
      scheme:           'MyScheme',
      extra_options:    [],
      xcode_build_dir:  '/tmp/appcircle_build_for_testing/BuildForTestinDir-UUID'
    }
  end

  # build() reads global state set by main.rb's top-level block, which the
  # __FILE__ guard keeps from running here. Each example controls it explicitly.
  around do |example|
    saved = [$configuration_name, $compiler_index_store_enable, $destination_flag, $random_uuid]
    $configuration_name          = nil
    $compiler_index_store_enable = nil
    $destination_flag            = nil
    $random_uuid                 = 'UUID'
    example.run
    $configuration_name, $compiler_index_store_enable, $destination_flag, $random_uuid = saved
  end

  # Capture the composed command instead of shelling out to the real toolchain.
  before do
    @last_cmd = nil
    allow(self).to receive(:runCommand) { |cmd| @last_cmd = cmd }
  end

  def build_command(overrides = {})
    build(base_args.merge(overrides))
    @last_cmd
  end

  context 'positive path – always-present flags' do
    it 'invokes xcodebuild' do
      expect(build_command).to start_with('xcodebuild ')
    end

    it 'quotes the scheme' do
      expect(build_command).to include('-scheme "MyScheme"')
    end

    it 'passes BUILD_DIR as the configured xcode build dir' do
      expect(build_command)
        .to include('BUILD_DIR="/tmp/appcircle_build_for_testing/BuildForTestinDir-UUID"')
    end

    it 'derives the derived-data path from the temporary path and uuid' do
      expect(build_command)
        .to include('-derivedDataPath "/tmp/appcircle_build_for_testing/BuildForTestingDerivedData-UUID"')
    end

    it 'uses the build-for-testing action' do
      expect(build_command).to include('build-for-testing')
    end

    it 'disables code signing' do
      expect(build_command)
        .to include('CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO')
    end

    it 'hands the composed command to runCommand exactly once' do
      expect(self).to receive(:runCommand).once
      build(base_args)
    end
  end

  context 'positive path – project type' do
    it 'passes -project for an .xcodeproj' do
      expect(build_command(project_path: 'App.xcodeproj')).to include('-project "App.xcodeproj"')
    end

    it 'passes -workspace for an .xcworkspace' do
      expect(build_command(project_path: 'App.xcworkspace')).to include('-workspace "App.xcworkspace"')
    end

    it 'does not pass -workspace for an .xcodeproj' do
      expect(build_command(project_path: 'App.xcodeproj')).not_to include('-workspace')
    end

    it 'does not pass -project for an .xcworkspace' do
      expect(build_command(project_path: 'App.xcworkspace')).not_to include('-project ')
    end

    it 'joins a relative project path onto the repository path' do
      cmd = build_command(repository_path: '/repo', project_path: 'App.xcodeproj')
      expect(cmd).to include('-project "/repo/App.xcodeproj"')
    end

    it 'keeps an absolute project path when a repository path is also given' do
      cmd = build_command(repository_path: '/repo', project_path: '/elsewhere/App.xcodeproj')
      expect(cmd).to include('-project "/elsewhere/App.xcodeproj"')
    end

    it 'uses the bare project path when no repository path is given' do
      cmd = build_command(repository_path: nil, project_path: 'App.xcodeproj')
      expect(cmd).to include('-project "App.xcodeproj"')
    end
  end

  context 'positive path – optional flags' do
    it 'adds -configuration when $configuration_name is set' do
      $configuration_name = 'Release'
      expect(build_command).to include('-configuration "Release"')
    end

    it 'adds COMPILER_INDEX_STORE_ENABLE when the global is set' do
      $compiler_index_store_enable = 'NO'
      expect(build_command).to include('COMPILER_INDEX_STORE_ENABLE=NO')
    end

    it 'adds -destination when $destination_flag is set' do
      $destination_flag = 'generic/platform=iOS'
      expect(build_command).to include('-destination "generic/platform=iOS"')
    end

    it 'appends each extra option in order' do
      cmd = build_command(extra_options: ['-quiet', '-allowProvisioningUpdates'])
      expect(cmd.index('-quiet')).to be < cmd.index('-allowProvisioningUpdates')
    end

    it 'combines every optional flag in a single command' do
      $configuration_name          = 'Debug'
      $compiler_index_store_enable = 'YES'
      $destination_flag            = 'generic/platform=iOS'
      cmd = build_command(extra_options: ['-quiet'])
      expect(cmd).to include('-configuration "Debug"')
      expect(cmd).to include('COMPILER_INDEX_STORE_ENABLE=YES')
      expect(cmd).to include('-destination "generic/platform=iOS"')
      expect(cmd).to include('-quiet')
    end

    it 'keeps the project flag last, after the extra options' do
      cmd = build_command(extra_options: ['-quiet'])
      expect(cmd.index('-quiet')).to be < cmd.index('-project')
    end
  end

  context 'negative path – optional flags left unset' do
    it 'omits -configuration when $configuration_name is nil' do
      expect(build_command).not_to include('-configuration')
    end

    it 'omits COMPILER_INDEX_STORE_ENABLE when the global is nil' do
      expect(build_command).not_to include('COMPILER_INDEX_STORE_ENABLE')
    end

    it 'omits -destination when $destination_flag is nil' do
      expect(build_command).not_to include('-destination')
    end

    it 'still emits an empty -configuration value for an empty configuration name' do
      $configuration_name = ''
      expect(build_command).to include('-configuration ""')
    end

    it 'still emits an empty -destination value for an empty destination flag' do
      $destination_flag = ''
      expect(build_command).to include('-destination ""')
    end
  end

  context 'negative path – empty and malformed input' do
    it 'raises TypeError when the project path is nil' do
      expect { build(base_args.merge(project_path: nil)) }.to raise_error(TypeError)
    end

    it 'raises TypeError when args is an empty hash' do
      expect { build({}) }.to raise_error(TypeError)
    end

    it 'raises NoMethodError when args is nil' do
      expect { build(nil) }.to raise_error(NoMethodError)
    end

    it 'emits an empty scheme rather than failing when the scheme is nil' do
      expect(build_command(scheme: nil)).to include('-scheme ""')
    end

    it 'emits an empty scheme for an empty scheme string' do
      expect(build_command(scheme: '')).to include('-scheme ""')
    end

    it 'ignores extra_options when it is not an Array' do
      expect(build_command(extra_options: '-quiet')).not_to include('-quiet')
    end

    it 'ignores extra_options when it is nil' do
      expect { build_command(extra_options: nil) }.not_to raise_error
    end

    it 'adds neither -project nor -workspace for an unrecognised extension' do
      cmd = build_command(project_path: 'App.txt')
      expect(cmd).not_to include('-project ')
      expect(cmd).not_to include('-workspace')
    end

    it 'adds neither -project nor -workspace for a path with no extension' do
      cmd = build_command(project_path: 'App')
      expect(cmd).not_to include('-project ')
      expect(cmd).not_to include('-workspace')
    end

    it 'propagates the failure when runCommand raises' do
      allow(self).to receive(:runCommand).and_raise(RuntimeError, 'xcodebuild failed')
      expect { build(base_args) }.to raise_error(RuntimeError, /xcodebuild failed/)
    end
  end
end

# ─── 4. ENV validation (subprocess – main.rb) ─────────────────────────────────
RSpec.describe 'ENV validation (subprocess – main.rb)' do
  let(:tmpdir) { Dir.mktmpdir('build_for_testing_env') }
  after { FileUtils.rm_rf(tmpdir) }

  shared_examples 'aborts with message' do |expected_pattern, env|
    it "exits non-zero and stderr matches /#{expected_pattern}/" do
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(Regexp.new(expected_pattern))
    end
  end

  context 'AC_TEMP_DIR' do
    context 'when missing' do
      include_examples 'aborts with message', 'Missing temporary path\.', {}
    end

    context 'when an empty string' do
      # main.rb only nil-checks this variable, so an empty value passes through
      # and the run stops at the next unset required variable instead.
      include_examples 'aborts with message',
                       'Missing project path\.',
                       { 'AC_TEMP_DIR' => '' }
    end
  end

  context 'AC_PROJECT_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing project path\.',
                       { 'AC_TEMP_DIR' => '/tmp' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing scheme\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_PROJECT_PATH' => '' }
    end
  end

  context 'AC_SCHEME' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing scheme\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_PROJECT_PATH' => 'App.xcodeproj' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       {
                         'AC_TEMP_DIR'     => '/tmp',
                         'AC_PROJECT_PATH' => 'App.xcodeproj',
                         'AC_SCHEME'       => ''
                       }
    end
  end

  context 'AC_COMPILER_INDEX_STORE_ENABLE' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       {
                         'AC_TEMP_DIR'     => '/tmp',
                         'AC_PROJECT_PATH' => 'App.xcodeproj',
                         'AC_SCHEME'       => 'MyScheme'
                       }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       {
                         'AC_TEMP_DIR'                    => '/tmp',
                         'AC_PROJECT_PATH'                => 'App.xcodeproj',
                         'AC_SCHEME'                      => 'MyScheme',
                         'AC_COMPILER_INDEX_STORE_ENABLE' => ''
                       }
    end
  end

  context 'AC_ENV_FILE_PATH' do
    it 'succeeds and writes every output variable when set' do
      env_file = File.join(tmpdir, 'env_file')
      _out, err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      contents = File.read(env_file)
      %w[AC_TEST_APP_PATH AC_UITESTS_RUNNER_PATH AC_XCTEST_PATH
         AC_UITESTS_RUNNER_IPA_PATH AC_XCTEST_ZIP_PATH AC_TEST_IPA_PATH].each do |key|
        expect(contents).to include("#{key}=")
      end
    end

    it 'appends to an existing env file rather than truncating it' do
      env_file = File.join(tmpdir, 'env_file')
      File.write(env_file, "PRE_EXISTING=1\n")
      _out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(File.read(env_file)).to include('PRE_EXISTING=1')
    end

    it 'fails with a TypeError when missing' do
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => nil))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/TypeError|no implicit conversion/)
    end

    it 'fails with a missing-file error when an empty string' do
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end

    it 'fails when it points into a directory that does not exist' do
      _out, err, status = run_main(
        full_env(tmpdir).merge('AC_ENV_FILE_PATH' => File.join(tmpdir, 'no', 'such', 'dir', 'env'))
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end
  end

  context 'AC_REPOSITORY_DIR (optional)' do
    it 'succeeds when missing and uses the bare project path' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-project "App.xcodeproj"')
    end

    it 'succeeds when an empty string and uses the bare project path' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-project "App.xcodeproj"')
    end

    it 'joins the project path onto the repository dir when set' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => '/repo'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-project "/repo/App.xcodeproj"')
    end
  end

  context 'AC_DESTINATION (optional)' do
    it 'omits -destination when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-destination')
    end

    it 'passes the value through when set' do
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_DESTINATION' => 'generic/platform=iOS')
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-destination "generic/platform=iOS"')
    end

    it 'emits an empty -destination for an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_DESTINATION' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-destination ""')
    end
  end

  context 'AC_CONFIGURATION_NAME (optional)' do
    it 'omits -configuration when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-configuration')
    end

    it 'passes the value through when set' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => 'Release'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-configuration "Release"')
    end

    it 'omits -configuration for an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-configuration')
    end
  end

  context 'AC_ARCHIVE_FLAGS (optional)' do
    it 'omits extra flags when missing' do
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-quiet')
    end

    it 'splits a pipe-separated value into separate flags' do
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet|-parallelizeTargets')
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-quiet')
      expect(out).to include('-parallelizeTargets')
    end

    it 'omits extra flags for an empty string' do
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-quiet')
    end
  end

  context 'build failure' do
    it 'exits non-zero and surfaces stderr when xcodebuild fails' do
      _out, err, status = run_main(
        full_env(tmpdir),
        stub_source: XCODEBUILD_FAILING_STUB_SOURCE
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/stub-xcodebuild failure details/)
    end

    it 'does not write the env file when the build fails' do
      env_file = File.join(tmpdir, 'env_file')
      run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
      expect(File.exist?(env_file)).to be(false)
    end
  end
end

# ─── 5. Loading main.rb as a library ──────────────────────────────────────────
RSpec.describe 'loading main.rb as a library' do
  it 'does not execute the step body when required' do
    out, _err, status = Open3.capture3(
      { 'AC_TEMP_DIR' => nil, 'AC_PROJECT_PATH' => nil, 'AC_SCHEME' => nil },
      RbConfig.ruby, '-e', "require '#{MAIN_RB}'; puts 'loaded'"
    )
    expect(status.exitstatus).to eq(0)
    expect(out).to include('loaded')
    expect(out).not_to include('@@[command]')
  end

  it 'defines every function under test' do
    out, _err, status = Open3.capture3(
      RbConfig.ruby, '-e',
      "require '#{MAIN_RB}'; " \
      "puts [:env_has_key, :build, :runCommand].all? { |m| respond_to?(m, true) }"
    )
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq('true')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
