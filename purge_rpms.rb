#!/bin/env ruby
#
# purge_rpms.rb - Purge rpm files from a yum repository
#
# Ryan Chapman
# Sat Nov 26 01:58:44 MST 2011

require 'optparse'
require 'open3'
require 'fileutils'
require 'rubygems'          # for comparing version strings
require 'rubygems/version'  # for comparing version strings
include Open3

# Default value for how many versions of a group of rpms to keep.  A group is determined by the %{NAME} of a rpm
NUM_RPM_TO_KEEP = 5


trap("SIGINT") { throw :ctrl_c }
catch :ctrl_c do 
  exit(1)
end

class RPM_Collection

  attr_reader :files

  def initialize()
    @files = []
    @rules = []
    # Add the default rule to end of rule list
    add_rule('.*', NUM_RPM_TO_KEEP)
  end

  def add_file(path_to_rpm_file)
    rpm_file = RPM_File.new(path_to_rpm_file)
    if rpm_file.is_rpm? then
      Logger.log(2, "Adding file to RPM_Collection: path_to_rpm_file=\'#{path_to_rpm_file}\'")
      @files.push(rpm_file)
    else
      Logger.log(2, "Not adding file to RPM_Collection (not an rpm): path_to_rpm_file=\'#{path_to_rpm_file}\'")
    end
  end

  def add_rule(rpm_regex, num_to_keep)
    Logger.log(2, "Adding rule to RPM_Collection: regex=\'#{rpm_regex}\', num_to_keep=\'#{num_to_keep}\'")
    rule = RPM_Rule.new(rpm_regex, num_to_keep.to_i)
    # Insert rule at the next to the last rule.  The last rule should always be the default rule, which is 
    # added in the constuctor for the RPM_Collection class
    @rules.insert(@rules.length-1, rule)
  end

  def files_to_keep
    file_counts = { }
    files_to_keep = []
    evaluate_rules()
    # reverse iterator so that the newest versions are listed first
    @files.reverse_each do |file|
      if file_counts.has_key?(file.name) == false then
        file_counts[file.name] = 1
        files_to_keep.push(file)
        file.keep = true
      else
        if file_counts[file.name] < file.rule.num_to_keep then
          file_counts[file.name] += 1
          files_to_keep.push(file)
          file.keep = true
        end
      end
    end #@files.reverse_each
    files_to_keep
  end # files_to_keep()

  def files_to_delete
    files_to_delete = @files - files_to_keep()
    files_to_delete
  end

  private
  def evaluate_rules
    @files.sort!
    @files.each do |file|
        file.keep = false
    end

    @files.each do |file|
      found = false
      @rules.each do |rule|
        if not found then
          Logger.log(3, "Rule=#{rule}")
          if /^#{rule.regex}$/.match(file.name) then
            file.rule = rule
            found = true
            Logger.log(4, "Rule MATCH: file=\'#{file}\', keeping #{file.rule.num_to_keep} versions of this name")
          end
        end # if not found
      end # @rules.each
    end # @files.each
  end # evaluate_rules()

end # class RPM_Collection


class RPM_Rule

  attr_reader :regex, :num_to_keep

  def initialize(rpm_regex, num_to_keep)
    @regex = rpm_regex
    @num_to_keep = num_to_keep
  end

  def to_s
    "RPM_Rule: regex=#{@regex}, num_to_keep=#{num_to_keep}"
  end

end # class RPM_Rule


class RPM_File
  include Comparable

  attr_reader :name, :version, :release, :arch, :filename
  attr_accessor :rule # what RPM_Rule applies to this file
  attr_accessor :keep # do we want to delete this file?

  def initialize(filename)
    @filename = filename
    parse()
  end

  def parse()
    errors = nil
    output = nil
    # are we dealing with an rpm?
    magic = `file -b \'#{filename}\'`.chomp
    if /^[Rr][Pp][Mm]/.match(magic) then
      @is_rpm = true
    else
      @is_rpm = false
      return
    end

    # TODO: switch to 'ruby-rpm' gem if this is too slow
    popen3('/bin/rpm', '--nosignature', '--nodigest','--queryformat', '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}', 
           '-qp', @filename) do |stdin, stdout, stderr, waitthread|
      stdin.close_write
      output = stdout.read.chomp
      errors = stderr.read.chomp
    end
    if errors.nil? == false && errors != "" then
      raise "Error executing /bin/rpm -qp --queryformat ...: #{errors}"
    end
    arr = output.split(/\|/)
    @name = arr[0]
    @version = arr[1]
    @release = arr[2]
    @arch = arr[3]
  end

  def is_rpm?
    @is_rpm
  end

  def keep?
    @keep
  end

  def <=>(other)
    if @name < other.name then
      return -1
    elsif @name > other.name then
      return 1
    end

    selfver = Gem::Version.new(@version)
    otherver = Gem::Version.new(other.version)
    if selfver < otherver then
      return -1
    elsif selfver > otherver then
      return 1
    end

    selfrelease = Gem::Version.new(@release)
    otherrelease = Gem::Version.new(other.release)
    if selfrelease < otherrelease then
      return -1
    elsif selfrelease > otherrelease then
      return 1
    end

    if @arch < other.arch then
      return -1
    elsif @arch > other.arch then
      return 1
    end

    return 0
  end

  def to_s
    "name=#{@name}, version=#{@version}, release=#{@release}, arch=#{@arch}" 
  end
end # class



def main(args)
  options = { } 

  options[:rules] = []
  options[:dry_run] = false

  opts = OptionParser.new do |opts|
    opts.banner  = "Usage: #{$0} [arguments]\n"

    opts.on("-h", "--help", "Show this message") do |o| 
      puts opts
      exit 1
    end 

    opts.on("-d", "--dir=DIRECTORY", "DIRECTORY to purge rpm files from") do |o| 
      options[:directory] = o 
    end 

    opts.on("-v", "Print information about what is happening.",
            "Use multiple times for additional verbosity (e.g. -vvv)") do |o| 
      Logger.increase_verbosity
      options[:verbose] = o
    end 

    opts.on("--rule=[\'FILE_REGEX,NUM_TO_KEEP\']", 
            "Rule pair which consists of a regular expression describing",
            "a group of rpm files and how many files of this type to keep.",
            "By default, the last #{NUM_RPM_TO_KEEP} versions of a rpm group are kept",
            "Multiple instances of --rule may be specified for different groups of rpm files") do |o| 
      options[:rules].push(o)
    end 
    
    opts.on("--dry-run", "Show what would occur, but do not actually remove any files") do |o|
      options[:dry_run] = o
    end

    opts.separator ""
    opts.on_tail("Examples: #{$0} --dir=/www/yum/5/x86_64 --rule=\'vmware.*,2\' --rule=\'lsof.*,1\'",
                 "          This would search in the /www/yum/5/x86_64 directory:",
                 "          -keeping 2 copies of all rpms with a %{NAME} matching the regex \'vmware.*\'",
                 "          -keeping 1 copy of all rpms with a %{NAME} matching the regex \'lsof.*\'",
                 "          -keeping 5 copies of all other rpms (the default rule)",
                 "",
                 "          #{$0} --dir=/www/yum/4/i386 --rule=\'lsof.*,1\' --rule=\'lsof.*,10\'",
                 "          This would search in the /www/yum/4/i386 directory:",
                 "          -keeping 1 copy of all rpms with a %{NAME} matching the regex \'lsof.*\'",
                 "           (this is because the first matching rule wins)",
                 "          -keeping 5 copies of all other rpms (the default rule)",
                 "",
                 "          #{$0} --dir=/www/yum/5/x86_64 --rule='lsof.*,10\' --rule=\'.*,3\'",
                 "          This would search in the /www/yum/5/x86_64 directory:",
                 "          -keeping 10 copies of all rpms with a %{NAME} matching the regex \'lsof.*\'",
                 "          -keeping 3 copies of all other rpms (overriding the default rule)")

  end 

  opts.parse!(args)
  # Do we have all required args? If not, print usage and exit
  if options[:directory].nil? 
    puts opts
    exit 1
  end 


  rpm_collection = RPM_Collection.new()

  # Parse rules and put them in the RPM_Collection
  if options[:rules].length > 0 then
    options[:rules].each do |rule|
      if rule.nil?
        invalid_rule(rule)
        exit 1
      end
      (regex, num_to_keep) = rule.split(/,/)
      if regex.nil? || num_to_keep.nil? then
        invalid_rule(rule)
        exit 1
      end
      rpm_collection.add_rule(regex, num_to_keep)
    end
  end

  # Add rpm files to RPM_Collection
  Dir[options[:directory] + '/**'].each do |file|
    rpm_collection.add_file(file)
  end

  # Build list of files to be kept and deleted, sort by filename.  Display to user as files are deleted
  rpm_collection.files_to_keep
  
  if options[:dry_run] then
    Logger.log(1, "Dry mode invoked.  Not actually deleting any files")
  end
  rpm_collection.files.each do |f|
    if f.keep? then
        keep_indicator = '+'
    else
        keep_indicator = '-'
    end
    puts keep_indicator + " " + f.filename
    if options[:dry_run] == false and f.keep? == false then
      new_dir = File.dirname(f.filename) + "/.remove/"
      Logger.log(2, "Move #{f.filename} -> #{new_dir}")
      FileUtils.mkdir(new_dir) if not File.directory? new_dir
      FileUtils.mv(f.filename, new_dir, :force => true)
    end
  end

end

def invalid_rule(rule)
  puts "ERROR: Invalid rule: \'#{rule}\'"
  puts "Rules must of the form \'regular_express,number_of_rpms_to_keep\'"
  puts "For example, \'vmware.*,10\'"
end


class Logger

  @@verbosity_level = 0

  def Logger.increase_verbosity
    @@verbosity_level += 1
  end

  def Logger.log(level, msg)
    if @@verbosity_level >= level then
      formatted_msg  = " "
      formatted_msg += '*' * level
      formatted_msg += " "
      formatted_msg += msg
      puts formatted_msg
    end
  end

end # class Logger


main(ARGV)
