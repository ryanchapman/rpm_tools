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
require 'uri'
require 'zlib'
require 'open3'
include REXML
include Open3


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
        raise " ** HTTP request to #{filelist_uri} returned HTTP code: #{resp.code}: #{resp.body}"
      end
      data = resp.body
      # Decompress .gz file
      zstream = Zlib::Inflate.new(15+32)    # if you dont specify window_bits=15+32, then Zlib::DataError will be thrown
      xml_as_string = zstream.inflate(data)
      zstream.finish
      zstream.close
    }
    log(" *  Got index #{filelist_uri}")

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
          log(" *  Adding to download list: #{uri}")
          filenames.push(uri)
        end 
      }
    }
    return filenames
  end

  # Returns a list of files that need to be signed using rpm
  def download_file(file_uri, dest_dir)
    uri = URI.parse(file_uri)
    rpms_to_sign = []
    Net::HTTP.start(uri.host) { |http|
      resp = http.get(uri.request_uri)
      if resp.code != "200" then
        raise " ** HTTP request to #{file_uri} returned HTTP code: #{resp.code}: #{resp.body}"
      end
      dest_file = dest_dir + "/" + File.basename(uri.path)
      if File.exist?(dest_file) then
        log(" *  RPM #{dest_file} already downloaded")
      else
        open(dest_file, "wb") { |dest| dest.write(resp.body) }
        log(" *  Downloaded #{file_uri} to #{dest_file}")
        if @options[:sign] == true then
          log(" *  Calling /bin/rpm --addsign #{dest_file}:")
          popen3('/bin/rpm', '--addsign', dest_file) do |stdin, stdout, stderr, waitthread|
            stdin.close_write
            print stdout.read
            errors = stderr.read
            errors.gsub!(/^gpg: WARNING: standard input reopened\n/, "")
            print errors
          end
        end
      end
    }
  end

  def log(message)
    if @options[:verbose] == true then
      puts message
    end
  end
end #class RPM_Repository

######################
#### MAIN ############
######################
def main(args)
  options = { }
  options[:verbose] = false
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

    opts.on("--[no-]sign", "Do or don\'t sign downloaded rpm files. Default is to sign rpm files.") do |o|
      options[:sign] = o
    end

    opts.on("-v","--[no-]verbose", "Print information about what is happening") do |o|
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
  rpm_repo.log(" ** Beginning synchronization")
  rpm_repo.synchronize()
  rpm_repo.log(" ** Done")

end

main(ARGV)
