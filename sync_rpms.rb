#!/usr/local/bin/ruby
#
# Synchronize RPMs from a remote yum repository to a yum repo on this machine.
#
# Does this by:
# 1. Downloading .../repodata/filelists.xml.gz
# 2. Given the files in filelists.xml.gz, if a file matches the regex specified in
#    the command line options, then:
#    a. Check to see if the file already exists locally. If it does not, then
#       download file and sign it using rpm --addsign
#
# Ryan Chapman, ryan@heatery.com
# Sat Nov 26 00:59:57 MST 2011

require 'optparse'
require 'ostruct'
require 'rexml/document'
require 'net/http'
require 'net/smtp'
require 'uri'
require 'zlib'
require 'etc'
require 'socket'
require 'open3'
include REXML
include Open3


class Logger

  @@verbosity_level = 0

  def Logger.increase_verbosity
    @@verbosity_level += 1
  end

  def Logger.formatted_message(level, msg)
    formatted_msg  = " "
    formatted_msg += '*' * level
    formatted_msg += " "
    formatted_msg += msg
    formatted_msg
  end

  def Logger.log(level, msg)
    if @@verbosity_level >= level then
     puts Logger.formatted_message(level, msg)
    end
  end

end # class Logger


class RPM_Repository

  def initialize(options)
    @options = options
  end

  def synchronize()
    all_rpms = filelist_from_url(@options[:repo_url], @options[:match_regex])
    all_rpms.each { |file| download_file(file, @options[:dest_folder]) }
  end

  def filelist_from_url(repo_uri, regex_pattern)
    filelist_uri = repo_uri + "/repodata/filelists.xml.gz"
    filelist_uri = URI.parse(filelist_uri)

    xml_as_string = nil
    Net::HTTP.start(filelist_uri.host) { |http|
      resp = http.get(filelist_uri.request_uri)
      if resp.code != "200" then
        raise Logger.formatted_message(2, "HTTP request to #{filelist_uri} returned HTTP code: #{resp.code}: #{resp.body}")
      end
      data = resp.body

      # Decompress .gz file
      zstream = Zlib::Inflate.new(15+32)    # if you dont specify window_bits=15+32, then Zlib::DataError will be thrown
      xml_as_string = zstream.inflate(data)
      zstream.finish
      zstream.close
    }
    Logger.log(1, "Got index #{filelist_uri}")

    filenames = []
    xmldoc = Document.new(xml_as_string)
    xmldoc.elements.each("filelists/package") { |pkg_e|
      pkg_e.each_element("version") { |version_e|
        filename = pkg_e.attributes["name"] + "-"
        filename += version_e.attributes["ver"] + "-"
        filename += version_e.attributes["rel"] + "."
        filename += pkg_e.attributes["arch"] + ".rpm"
        if (/#{regex_pattern}/.match(filename)) then
          uri = repo_uri + "/" + filename
          Logger.log(1, "Adding to download list: #{uri}")
          filenames.push(uri)
        end 
      }
    }
    return filenames
  end

  def download_file(file_uri, dest_dir)
    uri = URI.parse(file_uri)
    Net::HTTP.start(uri.host) { |http|
      resp = http.get(uri.request_uri)
      if resp.code != "200" then
        raise Logger.formatted_message(2, "HTTP request to #{file_uri} returned HTTP code: #{resp.code}: #{resp.body}")
      end
      dest_file = dest_dir + "/" + File.basename(uri.path)
      if File.exist?(dest_file) then
        Logger.log(1, "RPM #{dest_file} already downloaded")
      else
        open(dest_file, "wb") { |dest| dest.write(resp.body) }
        Logger.log(1, "Downloaded #{file_uri} to #{dest_file}")
        puts "notify_emails=\"#{@options[:notify_emails]}"
        if @options[:notify_emails].nil? == false then
          @options[:notify_emails].gsub(/ /,'').split(",").each do |recipient|
            basename = File.basename(dest_file)
            Mailer.send_message(:to => recipient, 
                                :subject => "New rpm #{basename}", 
                                :body => "New rpm downloaded\n#{file_uri} => #{dest_file}")
          Logger.log(1, "Notification message sent to #{recipient}")
          end
        end
        if @options[:sign] == true then
          sign_rpm(dest_file)
        end
        if @options[:perms].nil? == false then
          setperms(dest_file, @options[:perms])
        end
      end
    }
  end

  def sign_rpm(dest_file)
    Logger.log(2, "Calling /bin/rpm --addsign #{dest_file}:")
    sign_success = false
    while sign_success == false
      popen3('/bin/rpm', '--addsign', dest_file) do |stdin, stdout, stderr, waitthread|
        stdin.close_write
        Logger.log(3, "rpm stdout=#{stdout.read}")
        errors = stderr.read
        errors.gsub!(/^gpg: WARNING: standard input reopened\n/, "")
        # I wish I could find a better way to do this.  But popen3 doesn't return the correct
        # exit code and popen4 requires ruby 1.9.0p0
        if errors.downcase =~ /pass phrase check failed/ then
          print "Incorrect pass phrase.  Try again (y/n) [n]? "
          response = STDIN.gets.chomp
          if response.downcase == "n" || response == "" then
            puts "Exiting. RPM was not signed correctly."
            Process.exit(1)
          end
          # some error other than invalid pass phrase
        elsif errors.downcase =~ /pass phrase is good/ then
          sign_success = true
        else
          puts errors
          Process.exit(1)
        end
      end # popen3
    end # while
  end

  def setperms(dest_file, perms)
    Logger.log(2, "Calling chmod(#{perms}, #{dest_file})")
    File.chmod(perms.to_i, dest_file)
  end

end #class RPM_Repository


class Mailer

  def Mailer.send_message(params)
    to = params[:to] or raise("Mailer.send_message(): required parameter :to was not passed in")
    subject = params[:subject] or raise("Mailer.send_message(): required parameter :subject was not passed in")
    body = params[:body] or raise("Mailer.send_message(): required parameter :body was not passed in")
    from  = "#{Etc.getpwuid.name}@#{Socket.gethostname}\n".chomp
    
    msg  = "From: #{from}\n" 
    msg += "To: #{to}\n"
    msg += "Subject: #{subject}\n\n"
    msg += "#{body}\n"

    Net::SMTP.start('localhost', 25) do |smtp|
      smtp.send_message(msg, from, to)
      smtp.finish
    end
  end

end

######################
#### MAIN ############
######################
def main(args)
  options = { }
  options[:sign] = true

  opts = OptionParser.new do |opts|
    opts.banner  = "Usage: #{$0} [arguments]\n"

    opts.on("-rURL", "--repo=URL", "URL of repository that you want to download rpms from") do |o|
      options[:repo_url] = o
    end

    opts.on("-mREGEX", "--match=REGEX", "Regular expression describing the filenames you want to download") do |o|
      options[:match_regex] = o
    end

    opts.on("-fFOLDER", "--dest=FOLDER", "FOLDER where rpm files should be downloaded to") do |o|
      options[:dest_folder] = o
    end

    opts.on("-e[EMAILS]", "--notify=[EMAILS]", "Send notifications to EMAILS when a new rpm is downloaded") do |o|
      options[:notify_emails] = o
    end

    opts.on("-p[PERMS]", "--perms=[PERMS]", "Set permissions on downloaded files.  For example, 0644") do |o|
      options[:perms] = o
    end

    opts.on("--[no-]sign", "Do or don\'t sign downloaded rpm files. Default is to sign rpm files.") do |o|
      options[:sign] = o
    end

    opts.on("-v", "Print information about what is happening.",
            "Use multiple times for additional verbosity (e.g. -vvv)") do |o|
      Logger.increase_verbosity  
      options[:verbose] = o
    end

    opts.on("-h", "--help", "Show this message") do |o|
      puts opts
      exit 1
    end

    opts.separator ""
    opts.on_tail("Example: #{$0} http://rpm.com/project/5/x86_64 'pstools.*' /www/yum/5/x86_64")
  end

  opts.parse!(args)
  if options[:repo_url].nil? || options[:match_regex].nil? || options[:dest_folder].nil?
    puts opts
    exit 1
  end

  rpm_repo = RPM_Repository.new(options)
  Logger.log(1, "Beginning synchronization")
  rpm_repo.synchronize()
  Logger.log(1, "Done")

end

main(ARGV)
