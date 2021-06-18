#!/usr/bin/env ruby

# This script is designed to be run against the source cluster to clean up
# projects that have been cloned to a destination cluster using e.g.
# auto-clone.rb. The benefits of doing this include:
#
# * avoid duplicate backups running in both clusters
# * avoid duplicate cronjobs running via either CLI pods or native cronjobs
# * reduce number of pods running in the source cluster
#
# The script performs these actions on the namespaces associated with the given list of projects.
#
# 1. scale down all deployments
# 2. suspend all k8s native cronjobs
# 3. remove any schedules.backup.appuio.ch objects
#
# The script will prompt for confirmation before running any commands. Use it like so:
#
#   ./post-clone-cleanup.rb -f project-list.txt

require 'optparse'
require 'open3'
require 'json'

def prompt_to_continue
  loop do
    printf "press 'y' to continue or ^C to exit: "
    prompt = STDIN.gets.chomp
    return if prompt == 'y'
  end
end

def safe_run_cmds(cmds)
  if cmds.empty?
    puts "nothing to do"
  else
    puts "run commands?", cmds.map{|cmd| cmd.join(' ')}
  end
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
  opts.banner = "Usage: post-clone-cleanup.rb -f project-list.txt"
  opts.on("-f", "--project-list FILE", "file containing a list of projects, one per line") do |f|
    options[:file] = f
  end
end

parser.parse!

unless %i(file).all?{|required| options.has_key?(required)}
  puts parser.banner
  exit 1
end

stdout, stderr, status = Open3.capture3('kubectl', 'config', 'current-context')
unless status.success?
  puts stdout, stderr
  exit 2
end
puts "!! about to clean up resources in cluster: #{stdout.chomp} !!"

puts "loading namespaces from cluster"
stdout, stderr, status = Open3.capture3('kubectl', 'get', 'ns', '-o', 'name')
unless status.success?
  puts stdout, stderr
  exit 2
end
namespaces = stdout.split

puts "loading deployments from cluster"
stdout, stderr, status = Open3.capture3('kubectl', 'get', 'deployments.apps', '-A', '-o', 'json')
unless status.success?
  puts stdout, stderr
  exit 2
end
deployments = JSON.load(stdout)['items']

puts "loading cronjobs from cluster"
stdout, stderr, status = Open3.capture3('kubectl', 'get', 'cronjob', '-A', '-o', 'json')
unless status.success?
  puts stdout, stderr
  exit 2
end
cronjobs = JSON.load(stdout)['items']

puts "loading (backup) schedules from cluster"
stdout, stderr, status = Open3.capture3('kubectl', 'get', 'schedules.backup.appuio.ch', '-A', '-o', 'json')
unless status.success?
  puts stdout, stderr
  exit 2
end
schedules = JSON.load(stdout)['items']

# enumerate projects from file
IO.readlines(options[:file], chomp: true).each do |project|
  # filter namespaces for project
  env_namespaces = namespaces.grep(/^namespace\/#{project}-/)

  puts "\ntargeted namespaces:"
  puts env_namespaces

  puts "\ngetting targeted namespaces contents:"
  list_cmds = env_namespaces.map do |ns|
    ['kubectl', '-n', ns.delete_prefix('namespace/'), 'get', 'all,pvc']
  end
  safe_run_cmds(list_cmds)

  puts "\nscaling down deployments in \"#{project}\" namespaces"
  scale_down_cmds = env_namespaces.map do |ns|
    deployments.select do |d|
      # select scaled-up deployments in project namespaces
      d['metadata']['namespace'] == ns.delete_prefix('namespace/') && d['spec']['replicas'] > 0
    end.map do |d|
      # generate scale down commannd
      ['kubectl', '-n', ns.delete_prefix('namespace/'), 'scale', 'deployment', d['metadata']['name'], '--replicas=0']
    end
  end.flatten(1)
  safe_run_cmds(scale_down_cmds)

  puts "\nsuspending cronjobs in \"#{project}\" namespaces"
  cronjob_suspend_cmds = env_namespaces.map do |ns|
    cronjobs.select do |c|
      # select active cronjobs in project namespaces
      c['metadata']['namespace'] == ns.delete_prefix('namespace/') && !c['spec']['suspend']
    end.map do |c|
      # generate suspend patch command
      ['kubectl', '-n', ns.delete_prefix('namespace/'), 'patch', 'cronjob', c['metadata']['name'], '-p', '{"spec" : {"suspend" : true }}']
    end
  end.flatten(1)
  safe_run_cmds(cronjob_suspend_cmds)

  puts "\ndeleting backup schedules in \"#{project}\" namespaces"
  schedule_delete_cmds = env_namespaces.map do |ns|
    schedules.select do |s|
      # select schedules in project namespaces
      s['metadata']['namespace'] == ns.delete_prefix('namespace/')
    end.map do |s|
      # generate suspend patch command
      ['kubectl', '-n', ns.delete_prefix('namespace/'), 'delete', 'schedules.backup.appuio.ch', s['metadata']['name']]
    end
  end.flatten(1)
  safe_run_cmds(schedule_delete_cmds)
end
