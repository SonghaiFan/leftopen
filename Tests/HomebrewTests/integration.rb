# Run with `brew ruby Tests/HomebrewTests/integration.rb`.
# Real Homebrew DSL/artifact dispatch, but EVERY external command is intercepted.
require "cask/cask_loader"
require "tmpdir"
require "fileutils"

calls = []
failure = false
SystemCommand.define_singleton_method(:run!) do |executable, **options|
  calls << [executable, options]
  raise "simulated authorization cancellation" if failure
  nil
end

Dir.mktmpdir("leftopen-cask-test-") do |directory|
  executable = File.join(directory, "LeftOpen.app/Contents/MacOS/LeftOpenApp")
  FileUtils.mkdir_p(File.dirname(executable))
  File.write(executable, "never executed\n")
  File.chmod(0o700, executable)
  config = Cask::Config.new(explicit: { appdir: directory })
  content = File.read(File.expand_path("../../Resources/Homebrew/leftopen.rb", __dir__))
  cask = Cask::CaskLoader::FromContentLoader.new(content).load(config: config)
  # An installed receipt can override initial config; keep this fixture isolated.
  cask.config = config
  flight = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::AbstractFlightBlock) }
  raise "No uninstall preflight" unless flight
  raise "Preflight must precede app removal" unless cask.artifacts.to_a.index(flight) <
    cask.artifacts.to_a.index { |artifact| artifact.is_a?(Cask::Artifact::App) }
  previous = ENV.delete("LEFTOPEN_UNINSTALL_CLEANED")
  begin
    %w[upgrade reinstall cleanup autoremove install].each do |operation|
      Homebrew.running_command = operation
      flight.uninstall_phase(upgrade: operation == "upgrade", reinstall: operation == "reinstall")
    end
    raise "Unexpected cleanup during upgrade/reinstall" unless calls.empty?
    Homebrew.running_command = "uninstall"
    flight.uninstall_phase
    command, options = calls.fetch(0)
    raise "Wrong helper: #{command.inspect}, args #{options[:args].inspect}; expected #{executable}" unless command == executable && options[:args] == ["--homebrew-cleanup"]
    raise "Wrong authorization/failure policy" unless options[:sudo] == false && options[:must_succeed] == true
    failure = true
    begin
      flight.uninstall_phase(force: true)
      raise "Cancellation did not stop uninstall"
    rescue RuntimeError => error
      raise unless error.message == "simulated authorization cancellation"
    end
    ENV["LEFTOPEN_UNINSTALL_CLEANED"] = "1"
    count = calls.length
    flight.uninstall_phase
    raise "Native app handoff recursed" unless calls.length == count
  ensure
    previous.nil? ? ENV.delete("LEFTOPEN_UNINSTALL_CLEANED") : ENV["LEFTOPEN_UNINSTALL_CLEANED"] = previous
  end
end
puts "Real Homebrew preflight dispatch passed; no cleanup commands executed."
