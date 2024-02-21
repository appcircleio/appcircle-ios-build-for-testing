require 'yaml'
require 'json'
require 'open3'
require 'pathname'
require 'securerandom'

###### Enviroment Variable Check
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

options = {}
options[:repository_path] = ENV["AC_REPOSITORY_DIR"]
options[:temporary_path] = ENV["AC_TEMP_DIR"] || abort('Missing temporary path.')
options[:temporary_path] += "/appcircle_build_for_testing"
options[:project_path] = ENV["AC_PROJECT_PATH"] || abort('Missing project path.')
options[:scheme] = ENV["AC_SCHEME"] || abort('Missing scheme.')

$destination_flag = ENV["AC_DESTINATION"]

$configuration_name = (ENV["AC_CONFIGURATION_NAME"] != nil && ENV["AC_CONFIGURATION_NAME"] !="") ? ENV["AC_CONFIGURATION_NAME"] : nil

#compiler_index_store_enable - Options: YES, NO
$compiler_index_store_enable = env_has_key("AC_COMPILER_INDEX_STORE_ENABLE")

options[:extra_options] = []

if ENV["AC_ARCHIVE_FLAGS"] != "" && ENV["AC_ARCHIVE_FLAGS"] != nil
  options[:extra_options] = options[:extra_options].concat(ENV["AC_ARCHIVE_FLAGS"].split("|"))
end

$random_uuid = SecureRandom.uuid
options[:xcode_build_dir] = "#{options[:temporary_path]}/BuildForTestinDir-#{$random_uuid}"

def build(args)
  repository_path = args[:repository_path]
  project_path = args[:project_path]
  scheme = args[:scheme]
  extname = File.extname(project_path)
  command = "xcodebuild -scheme \"#{scheme}\" BUILD_DIR=\"#{args[:xcode_build_dir]}\" -derivedDataPath \"#{args[:temporary_path]}/BuildForTestingDerivedData-#{$random_uuid}\" build-for-testing"
  
  command.concat(" ")
  command.concat("CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO")
  command.concat(" ")

  if $configuration_name != nil
    command.concat(" ")
    command.concat("-configuration \"#{$configuration_name}\"")
    command.concat(" ")
  end

  if $compiler_index_store_enable != nil
    command.concat(" ")
    command.concat("COMPILER_INDEX_STORE_ENABLE=#{$compiler_index_store_enable}")
    command.concat(" ")
  end

  if $destination_flag != nil
    command.concat(" ")
    command.concat("-destination \"#{$destination_flag}\"")
    command.concat(" ")
  end

  project_full_path = repository_path ? (Pathname.new repository_path).join(project_path) : project_path
  
  if args[:extra_options].kind_of?(Array)
    args[:extra_options].each do |option|
      command.concat(" ")
      command.concat(option)
      command.concat(" ")
    end
  end

  if extname == ".xcworkspace"
    command.concat(" -workspace \"#{project_full_path}\"")
  elsif extname == ".xcodeproj"
    command.concat(" -project \"#{project_full_path}\"")
  end


  runCommand(command)
end

def runCommand(command)
  puts "@@[command] #{command}"
  status = nil
  stdout_str = nil
  stderr_str = nil
  Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
    stdout.each_line do |line|
      puts line
    end
    stdout_str = stdout.read
    stderr_str = stderr.read
    status = wait_thr.value
  end

  unless status.success?
    raise stderr_str
  end
end

build(options)

ac_app_path = Dir["#{options[:xcode_build_dir]}/*/*.app"].select{ |f| !f.include? "Tests-Runner"}.map{ |f| File.absolute_path f }[0]
ac_uitests_runner_path = Dir["#{options[:xcode_build_dir]}/*/*.app"].select{ |f| f.include? "Tests-Runner"}.map{ |f| File.absolute_path f }[0]
ac_xctest_path= Dir["#{ac_app_path}/Plugins/*.xctest"].select{ |f| File.exist? f }.map{ |f| File.absolute_path f }[0]

if ac_app_path
  payload_path = "#{options[:xcode_build_dir]}/Payload"
  runCommand("mkdir -p #{payload_path}")
  runCommand("cp -r #{ac_app_path} #{payload_path}")

  ac_payload_zip_path = "#{payload_path}.zip"
  runCommand("cd #{File.dirname(payload_path)} && zip -r \"#{ac_payload_zip_path}\" \"#{File.basename(payload_path)}\"")

  ac_ipa_path = "#{File.dirname(ac_payload_zip_path)}/#{File.basename(ac_app_path,'.app')}.ipa"
  runCommand("cp -r \"#{ac_payload_zip_path}\" \"#{ac_ipa_path}\"")
end

if ac_uitests_runner_path
  payload_path = "#{options[:xcode_build_dir]}/PayloadUITestsRunner/Payload"
  runCommand("mkdir -p #{payload_path}")
  runCommand("cp -r #{ac_uitests_runner_path} #{payload_path}")

  ac_payload_zip_path = "#{payload_path}.zip"
  runCommand("cd #{File.dirname(payload_path)} && zip -r \"#{ac_payload_zip_path}\" \"#{File.basename(payload_path)}\"")

  ac_uitests_runner_ipa_path = "#{File.dirname(ac_payload_zip_path)}/#{File.basename(ac_uitests_runner_path,'.app')}.ipa"
  runCommand("cp -r \"#{ac_payload_zip_path}\" \"#{ac_uitests_runner_ipa_path}\"")
end

if ac_xctest_path
  ac_xctest_zip_path = "#{options[:xcode_build_dir]}/#{File.basename(ac_xctest_path)}.zip"
  runCommand("cd #{File.dirname(ac_xctest_path)} && zip -r \"#{ac_xctest_zip_path}\" \"#{File.basename(ac_xctest_path)}\"")
end

puts "AC_TEST_APP_PATH : #{ac_app_path}"
puts "AC_UITESTS_RUNNER_PATH : #{ac_uitests_runner_path}"
puts "AC_XCTEST_PATH : #{ac_xctest_path}"

puts "AC_UITESTS_RUNNER_IPA_PATH : #{ac_uitests_runner_ipa_path}"
puts "AC_XCTEST_ZIP_PATH : #{ac_xctest_zip_path}"
puts "AC_TEST_IPA_PATH : #{ac_ipa_path}"

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_TEST_APP_PATH=#{ac_app_path}"
  f.puts "AC_UITESTS_RUNNER_PATH=#{ac_uitests_runner_path}"
  f.puts "AC_XCTEST_PATH=#{ac_xctest_path}"
  f.puts "AC_UITESTS_RUNNER_IPA_PATH=#{ac_uitests_runner_ipa_path}"
  f.puts "AC_XCTEST_ZIP_PATH=#{ac_xctest_zip_path}"
  f.puts "AC_TEST_IPA_PATH=#{ac_ipa_path}"
}

exit 0