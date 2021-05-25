#!/usr/bin/env ruby

# This script just wraps the ./migrate-between-clusters.sh script.
#
# 1. put a list of projects in a file, newline separated.
# 2. run this wrapper script like so (Lagoon openshift ID must match destination cluster):
#
#   ./auto-clone.rb -s amazeeio-test9 -d amazeeio-test10 -o 140 -f projects

require 'optparse'
require 'open3'

def prompt_to_continue
  loop do
    printf "press 'y' to continue or ^C to exit: "
    prompt = STDIN.gets.chomp
    return if prompt == 'y'
  end
end

def safe_run_cmds(cmds)
  puts "run commands?", cmds.map{|cmd| cmd.join(' ')}
  prompt_to_continue
  cmds.each do |cmd|
    print "\n$ #{cmd.join(' ')}\n"
    system(*cmd, exception: true)
  end
end

trap "SIGINT" do
  puts "\nExiting"
  exit 130
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: auto-clone.rb -s source-kubectx -d dest-kubectx -o dest-openshift-ID -f project-list.txt"
  opts.on("-s", "--source-kubectx SOURCE", "source kubectx") do |s|
    options[:source] = s
  end
  opts.on("-d", "--destination-kubectx DEST", "destination kubectx") do |d|
    options[:dest] = d
  end
  opts.on("-f", "--project-list FILE", "file containing a list of projects, one per line") do |f|
    options[:file] = f
  end
  opts.on("-o", "--destination-openshift OPENSHIFT", "destination Lagoon openshift ID") do |o|
    options[:openshift] = o
  end
end

parser.parse!

unless %i(source dest file openshift).all?{|required| options.has_key?(required)}
  puts parser.banner
  exit 1
end

# load namespaces from source cluster
puts "loading namespaces from source cluster"
stdout, stderr, status = Open3.capture3(*['kubectl', '--context', options[:source], 'get', 'ns', '-o', 'name'])
unless status.success?
  puts stdout, stderr
  exit 2
end
namespaces = stdout.split

# enumerate projects from file
IO.readlines(options[:file], chomp: true).each do |project|
  # filter namespaces for project
  env_namespaces = namespaces.grep(/^namespace\/#{project}/)

  puts "\ntargeted namespaces:"
  puts env_namespaces

  puts "\ngetting targeted namespaces contents:"
  list_cmds = env_namespaces.map do |ns|
    ['kubectl', '--context', options[:source], '-n', ns.delete_prefix('namespace/'), 'get', 'all,pvc']
  end
  safe_run_cmds(list_cmds)

  puts "\ncloning namespaces for project \"#{project}\""
  clone_cmds = env_namespaces.map do |ns|
    ['./migrate-between-clusters.sh', '-z', 'skip', '-d', options[:dest], '-s', options[:source], '-n', ns.delete_prefix('namespace/')]
  end
  safe_run_cmds(clone_cmds)

  puts "\nswitching deploy target for project \"#{project}\" to #{options[:openshift]}:"
  safe_run_cmds([['lagoon', '-l', 'amazeeio', 'update', 'project', '--openshift', options[:openshift], '--project', project]])

  puts "\ndeploying all cloned environments for \"#{project}\":"
  deploy_cmds = env_namespaces.map do |ns|
    ['lagoon', '-l', 'amazeeio', 'deploy', 'latest', '--project', project, '--force', '--environment', ns.delete_prefix("namespace/#{project}-")]
  end
  safe_run_cmds(deploy_cmds)
end
