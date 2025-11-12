#!/usr/bin/env ruby

require 'colored'
require 'grit'
require 'git-up/version'

class GitUp
  VERSION = GitUp::VERSION if defined?(GitUp::VERSION)

  def run(argv)
    @fetch = true

    process_args(argv)

    if @fetch
      command = ['git', 'fetch', '--multiple']
      command << '--prune' if prune?
      command += config("fetch.all") ? ['--all'] : remotes

      # puts command.join(" ") # TODO: implement a 'debug' config option
      system(*command)
      raise GitError, "`git fetch` failed" unless $? == 0
    end

    @remote_map = nil # flush cache after fetch

    # Decide whether to use Git's --autostash or fall back to manual stash/pop
    use_autostash = (config("rebase.autostash") != 'false') && supports_autostash?

    Grit::Git.with_timeout(0) do
      if use_autostash
        # skip manual stashing because --autostash will handle it
        returning_to_current_branch do
          rebase_all_branches(use_autostash: true)
        end
      else
        with_stash do
          returning_to_current_branch do
            rebase_all_branches
          end
        end
      end
    end

    check_bundler
  rescue GitError => e
    puts e.message
    exit 1
  end

  def process_args(argv)
    banner = <<BANNER
Fetch and rebase all remotely-tracked branches.

    $ git up
    master         #{"up to date".green}
    development    #{"rebasing...".yellow}
    staging        #{"fast-forwarding...".yellow}
    production     #{"up to date".green}

    $ git up --no-fetch   # do not fetch, only rebase
    $ git up --version    # print version info
    $ git up --help       # print this message

There are no interesting command-line options, but
there are a few `git config` variables you can set.
For info on those and more, check out the man page:

    $ git up man

Or install it to your system, so you can get to it with
`man git-up` or `git help up`:

    $ git up install-man

BANNER

    man_path = File.expand_path('../../man/git-up.1', __FILE__)

    case argv
    when []
      return
    when ["-v"], ["--version"]
      $stdout.puts "git-up #{GitUp::VERSION}"
      exit
    when ["man"]
      system "man", man_path
      exit
    when ["install-man"]
      destination = "/usr/local/share/man"
      print "Destination to install man page to [#{destination}]: "
      override = $stdin.gets.strip
      destination = override if override.length > 0

      dest_dir  = File.join(destination, "man1")
      dest_path = File.join(dest_dir, File.basename(man_path))

      exit(1) unless system "mkdir", "-p", dest_dir
      exit(1) unless system "cp", man_path, dest_path

      puts "Installed to #{dest_path}"

      exit
    when ["-h"], ["--help"]
      $stderr.puts(banner)
      exit
    when ["-no-f"], ["--no-fetch"]
      @fetch = false
    else
      $stderr.puts(banner)
      exit 1
    end
  end

  def rebase_all_branches(options = {})
    col_width = branches.map { |b| b.name.length }.max + 1

    branches.each do |branch|
      remote = remote_map[branch.name]

      curbranch = branch.name.ljust(col_width)
      if branch.name == repo.head.name
        print curbranch.bold
      else
        print curbranch
      end

      if remote.commit.sha == branch.commit.sha
        puts "up to date".green
        next
      end

      base = merge_base(branch.name, remote.name)

      if base == remote.commit.sha
        puts "ahead of upstream".cyan
        next
      end

      if base == branch.commit.sha
        puts "fast-forwarding...".yellow
      elsif config("rebase.auto") == 'false'
        puts "diverged".red
        next
      else
        puts "rebasing...".yellow
      end

      log(branch, remote)
      checkout(branch.name)
      # pass option through so rebase() can add --autostash when appropriate
      rebase(remote, options)
    end
  end

  def repo
    @repo ||= get_repo
  end

  def get_repo
    repo_dir = `git rev-parse --show-toplevel`.chomp

    if $? == 0
      Dir.chdir repo_dir
      @repo = Grit::Repo.new(repo_dir)
    else
      raise GitError, "We don't seem to be in a git repository."
    end
  end

  def branches
    @branches ||= repo.branches.select { |b| remote_map.has_key?(b.name) }.sort_by { |b| b.name }
  end

  def remotes
    @remotes ||= remote_map.values.map { |r| r.name.split('/', 2).first }.uniq
  end

  def remote_map
    @remote_map ||= repo.branches.inject({}) { |map, branch|
      if remote = remote_for_branch(branch)
        map[branch.name] = remote
      end

      map
    }
  end

  def remote_for_branch(branch)
    remote_name   = repo.config["branch.#{branch.name}.remote"] || "origin"
    remote_branch = repo.config["branch.#{branch.name}.merge"] || branch.name
    remote_branch.sub!(%r{^refs/heads/}, '')
    repo.remotes.find { |r| r.name == "#{remote_name}/#{remote_branch}" }
  end

  # Return git version as [major, minor, patch]
  def git_version
    return @git_version if defined?(@git_version)
    ver_match = `git --version`.strip.match(/(\d+)\.(\d+)\.(\d+)/)
    if ver_match
      @git_version = ver_match.captures.map(&:to_i)
    else
      @git_version = [0,0,0]
    end
  end

  # Git supports --autostash for rebase/pull starting with Git 2.9
  def supports_autostash?
    maj, min, _ = git_version
    (maj > 2) || (maj == 2 && min >= 9)
  end

  def with_stash
    stashed = false

    if change_count > 0
      puts "stashing #{change_count} changes".magenta
      repo.git.stash
      stashed = true
    end

    yield

    if stashed
      puts "unstashing".magenta
      repo.git.stash({}, "pop")
    end
  end

  def returning_to_current_branch
    unless repo.head.respond_to?(:name)
      puts "You're not currently on a branch. I'm exiting in case you're in the middle of something.".red
      return
    end

    branch_name = repo.head.name

    yield

    unless on_branch?(branch_name)
      puts "returning to #{branch_name}".magenta
      checkout(branch_name)
    end
  end

  def checkout(branch_name)
    output = repo.git.checkout({}, branch_name)

    unless on_branch?(branch_name)
      raise GitError.new("Failed to checkout #{branch_name}", output)
    end
  end

  def log(branch, remote)
    if log_hook = config("rebase.log-hook")
      system('sh', '-c', log_hook, 'git-up', branch.name, remote.name)
    end
  end

  # rebase target_branch; options may include :use_autostash => true
  def rebase(target_branch, options = {})
    current_branch = repo.head
    arguments = config("rebase.arguments") || ''

    if options[:use_autostash]
      # ensure --autostash appears in the arguments (but avoid duplicates)
      unless arguments.include?('--autostash')
        arguments = (arguments + ' --autostash').strip
      end
    end

    output, err = repo.git.sh("#{Grit::Git.git_binary} rebase #{arguments} #{target_branch.name}")

    unless on_branch?(current_branch.name) and is_fast_forward?(current_branch, target_branch)
      raise GitError.new("Failed to rebase #{current_branch.name} onto #{target_branch.name}", output+err)
    end
  end

  def check_bundler
    return unless use_bundler?

    begin
      require 'bundler'
      ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile')
      Gem.loaded_specs.clear
      Bundler.setup
    rescue Bundler::GemNotFound, Bundler::GitError
      puts
      print 'Gems are missing. '.yellow

      if config("bundler.autoinstall") == 'true'
        puts "Running `bundle install`.".yellow
        system "bundle", "install"
      else
        puts "You should `bundle install`.".yellow
      end
    end
  end

  def is_fast_forward?(a, b)
    merge_base(a.name, b.name) == b.commit.sha
  end

  def merge_base(a, b)
    repo.git.send("merge-base", {}, a, b).strip
  end

  def on_branch?(branch_name=nil)
    repo.head.respond_to?(:name) and repo.head.name == branch_name
  end

  class GitError < StandardError
  end

  private

  def config(key)
    repo.config["git-up.#{key}"] || repo.config[key] || ENV["GIT_UP_#{key.upcase.gsub('.', '_')}"]
  end

  def prune?
    config("fetch.prune") != 'false'
  end

  def change_count
    `git status --porcelain`.lines.count
  end
end
