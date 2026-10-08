require "minitest/autorun"
require "pathname"

module Homebrew
  class << self
    attr_accessor :running_command
    def running_command_with_args; "brew #{@running_command}"; end
  end
end

class CaskFixture
  attr_reader :hook, :commands
  attr_accessor :failure, :helper_exists
  def initialize
    @commands = []
    @helper_exists = true
  end
  def cask(_name, &block); instance_eval(&block); end
  def version(*_args); "0.5.4"; end
  def appdir; self; end
  def /(_suffix); self; end
  def executable?; helper_exists; end
  def to_s; "/Applications/LeftOpen.app/Contents/MacOS/LeftOpenApp"; end
  def uninstall_preflight(&block); @hook = block; end
  def system_command(command, **options)
    @commands << [command, options]
    raise failure if failure
  end
  def method_missing(_name, *_args); end
  def run; instance_eval(&hook); end
end

class HomebrewUninstallTest < Minitest::Test
  def setup
    @previous = ENV.delete("LEFTOPEN_UNINSTALL_CLEANED")
    @cask = CaskFixture.new
    @cask.instance_eval(File.read(File.expand_path("../../Resources/Homebrew/leftopen.rb", __dir__)))
    Homebrew.running_command = "uninstall"
  end
  def teardown
    @previous.nil? ? ENV.delete("LEFTOPEN_UNINSTALL_CLEANED") : ENV["LEFTOPEN_UNINSTALL_CLEANED"] = @previous
  end
  def test_plain_uninstall_runs_user_session_cleanup_before_package_removal
    @cask.run
    command, options = @cask.commands.fetch(0)
    assert_equal "/Applications/LeftOpen.app/Contents/MacOS/LeftOpenApp", command
    assert_equal ["--homebrew-cleanup"], options[:args]
    assert_equal false, options[:sudo]
    assert_equal true, options[:must_succeed]
  end
  def test_upgrade_reinstall_and_automatic_cleanup_preserve_state
    %w[upgrade reinstall cleanup autoremove install].each do |operation|
      Homebrew.running_command = operation
      @cask.run
    end
    assert_empty @cask.commands
  end
  def test_native_app_handoff_prevents_recursive_cleanup
    ENV["LEFTOPEN_UNINSTALL_CLEANED"] = "1"
    @cask.run
    assert_empty @cask.commands
  end
  def test_cancelled_or_failed_cleanup_aborts_uninstall
    @cask.failure = "authorization cancelled"
    assert_raises(RuntimeError) { @cask.run }
  end
  def test_missing_helper_aborts_instead_of_silently_leaving_state
    @cask.helper_exists = false
    assert_raises(RuntimeError) { @cask.run }
    assert_empty @cask.commands
  end
  def test_unknown_command_context_never_runs_cleanup
    Homebrew.running_command = nil
    assert_raises(RuntimeError) { @cask.run }
    assert_empty @cask.commands
  end
end
