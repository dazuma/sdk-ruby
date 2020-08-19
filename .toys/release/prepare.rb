# frozen_string_literal: true

desc "Prepare a gem release"

flag :repo, "--repo=VAL", default: ::ENV["GITHUB_REPOSITORY"]
flag :release_ref, "--release-ref=VAL", default: ::ENV["GITHUB_REF"]
flag :git_remote, "--git-remote=VAL", default: "origin"
flag :gem_list, "--gem-list=VAL"
flag :user_name, "--user-name=VAL"
flag :user_email, "--user-email=VAL"
flag :override_version, "--override-version=VAL"
flag :yes, "--yes", "-y"

include :exec, exit_on_nonzero_status: true
include :terminal, styled: true
include :fileutils
include "release-tools"

def run
  cd context_directory

  set :release_ref, main_branch if release_ref.to_s.empty?

  set :gem_list, all_gems.join(" ") if gem_list.to_s.empty?
  set :override_version, nil if override_version.to_s.empty?
  set :user_name, nil if user_name.to_s.empty?
  set :user_email, nil if user_email.to_s.empty?

  gem_names = gem_list.split(/[\s\.]+/)

  puts "Running prechecks...", :bold
  verify_git_clean
  verify_github_checks repo
  gem_names.each { |gem_name| verify_no_duplicate_release gem_name }

  exec ["git", "fetch", "--unshallow", git_remote, release_ref]
  exec ["git", "fetch", git_remote, "--tags"]
  gem_names.each { |gem_name| prepare_release gem_name }
end

def prepare_release gem_name
  puts "Building release info for #{gem_name} ...", :bold
  gem_directory = gem_info gem_name, "directory"
  release_info = ReleaseInfo.new gem_name, gem_directory, release_ref, override_version, self

  puts "Last version: #{release_info.last_version}", :bold if release_info.last_version
  puts "Changelog:", :bold
  puts release_info.full_changelog
  puts
  if !yes && !confirm("Create release PR? ", :bold, default: true)
    error "Release aborted"
  end

  gem_cd gem_name do
    modify_version release_info
    modify_changelog release_info
  end
  create_release_commit release_info
  create_release_pr release_info
end

def verify_no_duplicate_release gem_name
  prs = find_release_prs repo, gem_name: gem_name
  unless prs.empty?
    pr_number = prs.first["number"]
    error "A release PR ##{pr_number} already exists for #{gem_name}"
  end
end

def modify_version release_info
  path = gem_info release_info.gem_name, "version_rb_path"
  content = ::File.read path
  content.sub!(/VERSION = "\d+\.\d+\.\d+"/, "VERSION = \"#{release_info.new_version}\"")
  ::File.open(path, "w") { |file| file.write content }
end

def modify_changelog release_info
  path = "CHANGELOG.md"
  content = ::File.read path
  content.sub!(
    %r{### (v\d+\.\d+\.\d+ / \d\d\d\d-\d\d-\d\d)},
    "#{release_info.full_changelog}\n\n### \\1"
  )
  ::File.open(path, "w") { |file| file.write content }
end

def create_release_commit release_info
  exec ["git", "config", "user.email", user_email] if user_email
  exec ["git", "config", "user.name", user_name] if user_name
  exec ["git", "checkout", "-b", release_info.release_branch_name]
  exec ["git", "commit", "-a", "-m", release_info.release_commit_title]
  exec ["git", "push", "-f", git_remote, release_info.release_branch_name]
  exec ["git", "checkout", main_branch]
end

def create_release_pr release_info
  pr_body = <<~STR
    Release #{release_info.gem_name} #{release_info.new_version}.
    Changelog:

    ---

    #{release_info.full_changelog}

    ---

    Feel free to edit the changlog and/or version if desired.
    To trigger a release, merge this PR with the #{release_pending_label.inspect} label set.
    To abort the release, close this PR without merging.
  STR
  body = ::JSON.dump({
    title: release_info.release_commit_title,
    head: release_info.release_branch_name,
    base: main_branch,
    body: pr_body,
    maintainer_can_modify: true
  })
  exec ["gh", "api", "repos/#{repo}/pulls", "--input", "-",
        "-H", "Accept: application/vnd.github.v3+json"], in: [:string, body]
end

class ReleaseInfo
  def initialize gem_name, gem_directory, release_ref, override_version, context
    @context = context
    @gem_name = gem_name
    @gem_directory = gem_directory
    @release_ref = release_ref
    init_analysis
    determine_last_version
    analyze_messages
    determine_new_version override_version
    build_changelog_entries
    build_full_changelog
    build_commit_info
  end

  attr_reader :gem_name
  attr_reader :gem_directory
  attr_reader :last_version
  attr_reader :new_version
  attr_reader :changelog_entries
  attr_reader :date
  attr_reader :full_changelog
  attr_reader :release_commit_title
  attr_reader :release_branch_name

  private

  def init_analysis
    @bump_segment = 2
    @feats = []
    @fixes = []
    @docs = []
    @breaks = []
    @others = []
  end

  def determine_last_version
    @last_version = @context.capture(["git", "tag", "-l"])
      .split("\n")
      .map do |tag|
        if tag =~ %r|^#{@gem_name}/v(\d+\.\d+\.\d+)$|
          ::Gem::Version.new($1)
        end
      end
      .compact
      .max
  end

  def analyze_messages
    shas =
      if @last_version
        @context.capture(["git", "log", "#{@gem_name}/v#{@last_version}^..#{@release_ref}", "--format=%H"]).split("\n").reverse
      else
        []
      end
    (0..(shas.length - 2)).each do |index|
      sha1 = shas[index]
      sha2 = shas[index + 1]
      unless gem_directory == "."
        files = @context.capture(["git", "diff", "--name-only", "#{sha1}..#{sha2}"]).split("\n")
        next unless files.any? { |file| file.start_with? gem_directory }
      end
      messages = @context.capture(["git", "log", "#{sha1}..#{sha2}", "--format=%B"]).split("\n")
      analyze_message messages.first, messages[1..-1] unless messages.empty?
    end
  end

  def analyze_message title, body
    match = /^(fix|feat|docs)(?:\([^()]+\))?(!?):\s+(.*)$/.match title
    if match
      case match[1]
      when "fix"
        @fixes << match[3]
      when "docs"
        @docs << match[3]
      when "feat"
        @feats << match[3]
        @bump_segment = 1 if @bump_segment > 1
      end
      if match[2] == "!"
        @bump_segment = 0
        @breaks << match[3]
      end
    end
    body.each do |line|
      match = /^BREAKING(?:\s|-)CHANGE:\s+(.*)$/.match line
      if match
        @bump_segment = 0
        @breaks << match[1]
      end
    end
  end

  def determine_new_version override_version
    @new_version = override_version
    if @last_version
      @new_version ||= begin
        segments = @last_version.segments
        segments[@bump_segment] += 1
        segments.fill(0, @bump_segment + 1).join(".")
      end
    else
      @new_version ||= "0.1.0"
      @others << "Initial release."
    end
    @new_version = ::Gem::Version.new @new_version
  end

  def build_changelog_entries
    @changelog_entries = []
    unless @breaks.empty?
      @breaks.each do |line|
        @changelog_entries << "* BREAKING CHANGE: #{line}"
      end
      @changelog_entries << ""
    end
    @feats.each do |line|
      @changelog_entries << "* Feature: #{line}"
    end
    @fixes.each do |line|
      @changelog_entries << "* Fixed: #{line}"
    end
    @docs.each do |line|
      @changelog_entries << "* Documentation: #{line}"
    end
    @others.each do |line|
      @changelog_entries << "* #{line}"
    end
  end

  def build_full_changelog
    @date = ::Time.now.strftime "%Y-%m-%d"
    entries = @changelog_entries.empty? ? ["* (No significant changes)"] : @changelog_entries
    body = entries.join "\n"
    @full_changelog = "### v#{@new_version} / #{@date}\n\n#{body}"
  end

  def build_commit_info
    @release_commit_title = "release: Release #{@gem_name} #{@new_version}"
    @release_branch_name = @context.release_branch_name @gem_name
  end
end
