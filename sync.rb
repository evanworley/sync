#!/usr/bin/env ruby

require 'net/ftp'
require 'fileutils'
require 'yaml'

# TODO: Delete old files

DEFAULT_CONFIG_FILE = "sync_config.yml"
QUIET_TIME_FLAG = "disable_quiet_time.flag"

# Check command line arguments for the config file, else try for sync_config.yml in the current directory
if ARGV.length == 1
  config = YAML.load_file(ARGV.first)
elsif File.exists?(DEFAULT_CONFIG_FILE)
  config = YAML.load_file(DEFAULT_CONFIG_FILE)
else
  puts "Config missing: Create #{DEFAULT_CONFIG_FILE} in the current dir or specify as"
  puts "                the first command line arg"
  puts "Note: Run as root if you do not have permissions to place files into media_home"
  puts "Protip: To disable quiet time temporarily, create #{QUIET_TIME_FLAG} in the"
  puts "        current directory"
  puts ""
  puts "---- Configuration ----"
  puts "  Required"
  puts "    host: The host for your ftp server (e.g. 199.99.99.99)"
  puts "    username: The username for your host"
  puts "    password: The password for your host"
  puts "    root_dir: The directory on the host where we will download from"
  puts "              (e.g. downloads/complete)"
  puts "    media_home: The directory on this machine where the files will be placed."
  puts "  Optional"
  puts "    nice_speed: The download speed limit during quiet hours (e.g. 750K)"
  puts "    owner: The account name of the owner of the content. If specified the"
  puts "           content will be chowned"
  puts "    server_storage_limit: The maximum number of bytes the server can hold."
  puts "                          Old files will be deleted to stay within the limit"
  exit -1
end

# Set required config options
%w(host username password root_dir media_home).each do |key|
  raise "Required configuration option #{key} is missing" unless config.has_key?(key)
  instance_variable_set("@#{key}", config[key])
end

# Set optional config options
%w(nice_speed owner).each do |key|
  instance_variable_set("@#{key}", config[key]) if config.has_key?(key)
end

@log = File.open("sync.log", "a")
@log.sync = true

# Determines whether or not our download speed should be limited
def quiet_time?
  return false if File.exists?(QUIET_TIME_FLAG)
  now = Time.now

  # Weekends are quiet time, so is 6am-10am, and 5pm-1am
  if now.saturday? || now.sunday?
    return true
  elsif now.hour <  1 || (now.hour >= 6 && now.hour < 10) || now.hour >= 17
    return true
  else
    return false
  end
end

def dir?(bits)
  bits[0] == 'd'
end

def process_dir(dir)
  @log.puts "Processing directory #{@subdirs.join('/')}/#{dir}"
  @subdirs << dir

  @ftp.chdir(dir)

  process_current_dir

  @ftp.chdir("..")
  @subdirs.pop()
end

def download_file(name, size)
  # Make parent directories as needed
  path = "#{@media_home}/#{@subdirs.join('/')}"
  unless @subdirs.empty?
    FileUtils.mkdir_p(path)
    FileUtils.chown(@owner, @owner, path) if @owner
  end

  safe_name = name.gsub(' ', '_')

  file_path = File.join(path, safe_name)
  ftp_path = "ftp://#{@username}:#{@password}@#{@host}/#{@root_dir}/#{@subdirs.join('/')}/#{name}"

  file_exists = File.exists?(file_path)
  download_incomplete = File.exists?("#{file_path}.aria2")

  # If the file doesn't exist, isn't the right size, or the aria2c file is 
  # still there, resume it
  if !file_exists || download_incomplete || File.size(file_path) != size
    @log.puts "Downloading #{name}, #{(size / (1024.0 ** 2)).round(2)}MB"

    args = {}
    args["--summary-interval"] = "10"
    args["--max-connection-per-server"] = "6"
    args["--dir"] = "\"#{path}\""
    args["--out"] = "\"#{safe_name}\""

    if quiet_time?
      @log.puts "Quiet time enabled, limiting speed to #{@nice_speed}"
      args["--max-download-limit"] = @nice_speed
    end

    args_str = args.map{ |k, v| "#{k}=#{v}" }.join(' ')

    success = system("aria2c -c #{args_str} \"#{ftp_path}\" > aria2c.status 2>&1")
    if !success
      @log.puts "aria2c failed"
    end
    if @owner
      unless system("chown #{@owner}:#{@wner} \"#{file_path}\"")
        @log.puts "Failed to chown file, should you be running this as root?"
      end
    end
  end
end

def process_current_dir
  (@ftp.list rescue []).each do |file|
    pieces = file.split(/\s+/)

    bits = pieces[0]
    size = pieces[4].to_i
    name = pieces[8..-1].join(' ')

    if dir?(bits)
      process_dir(name)
    else
      download_file(name, size)
    end
  end
end

Signal.trap("SIGTERM") do
  @log.puts "SIGTERM received, shutting down"
  exit
end

while true do
  begin
    start = Time.now
    @log.puts "\n\n#{'-' * 20} Beginning update cycle #{'-' * 20}"

    @subdirs = []

    @ftp = Net::FTP.new(@host, @username, @password)
    @ftp.chdir(@root_dir)
    process_current_dir
    @ftp.close

    @log.puts "#{'-' * 20} Finished update cycle #{(Time.now - start)}s #{'-' * 20}"
    sleep 300
  rescue Exception => e
    @log.puts "Exception occured in main loop"
    @log.puts e
    @log.puts e.backtrace[0, 100].join("\n")
    @log.puts ""
    sleep 300
  end
end
